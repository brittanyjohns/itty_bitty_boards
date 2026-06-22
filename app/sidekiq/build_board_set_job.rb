# app/sidekiq/build_board_set_job.rb
#
# Async half of the Board Builder (POST /api/v1/board_builder). The controller
# does every synchronous pre-check (404 / 422 board-limit / 409 duplicate-set),
# creates the ROOT board with status "building_board", attaches it to the
# communicator (ChildBoard + favorite), and enqueues this job. This job builds
# everything else under that pre-created root:
#
#   - fringe/sub boards + their tiles
#   - predictive_board_id folder links
#   - interest -> category routing (+ a "My Favorites" fringe for leftovers)
#   - AI-art queuing for novel interest words (GenerateImagesJob)
#
# Phase 2 adds a hybrid build path driven by Boards::StructurePlanner:
#   - Clone the core seed set (with excluded fringe pages)
#   - Clone standalone fringe templates for categories not in the seed set
#   - AI-generate pages for niche interests (credit-gated, graceful fallback)
#   - Route catch-all interests to "My Favorites"
#
# Status lifecycle mirrors GenerateBoardJob: the ROOT (and only the root)
# carries the generation status — "building_board" -> "complete", or "failed"
# on any raise (then re-raise so Sidekiq retries once). Child boards keep
# their normal defaults; the frontend polls only the root.
class BuildBoardSetJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(root_board_id, communicator_id, level_or_template, interests = [], categories = {})
    root = Board.find_by(id: root_board_id)
    unless root
      Rails.logger.error "BuildBoardSetJob: Board with ID #{root_board_id} not found."
      return
    end

    if root.status == "complete" || root.board_images.exists?
      root.update_column(:status, "complete")
      return
    end

    communicator = ChildAccount.find_by(id: communicator_id)
    unless communicator
      Rails.logger.error "BuildBoardSetJob: ChildAccount with ID #{communicator_id} not found for Board ID #{root_board_id}."
      root.update_column(:status, "failed")
      return
    end

    begin
      explicit_categories = categories.is_a?(Hash) ? categories : {}

      if complexity_level?(level_or_template)
        build_with_structure_planner(root, communicator, level_or_template, interests, explicit_categories)
      elsif glp_template?(level_or_template)
        build_glp(root, communicator, level_or_template, interests)
      else
        build_legacy(root, communicator, level_or_template, interests, explicit_categories)
      end

      generate_preview!(root)
      root.update_column(:status, "complete")
    rescue => e
      Rails.logger.error "\n**** SIDEKIQ - BuildBoardSetJob #{root.id} #{level_or_template.inspect} \n\nERROR **** \n#{e.message}\n#{e.backtrace&.join("\n")}\n"
      root.update_column(:status, "failed")
      raise
    end
  end

  private

  def complexity_level?(value)
    Boards::StructurePlanner::LEVELS.key?(value.to_s.downcase)
  end

  def glp_template?(value)
    Boards::GlpTemplates.template_slug?(value.to_s)
  end

  # GLP templates are flat, admin-owned whole-phrase boards (one communicative
  # function each). Build = copy each phrase tile onto the pre-created root,
  # preserving order and part_of_speech ("phrase"). Any interests the caregiver
  # picked in the wizard fold into a "My Favorites" page so nothing is dropped.
  def build_glp(root, communicator, slug, interests)
    source = Boards::GlpTemplates.find_board(slug)
    raise Boards::BlueprintAssembler::UnknownTemplate, "unknown glp template #{slug.inspect}" unless source

    source.board_images.order(:position).each do |board_image|
      root.add_image(board_image.image_id)
    end

    add_to_favorites!(root, communicator, interests) if interests.present?
  end

  # Phase 2: StructurePlanner-driven hybrid build.
  def build_with_structure_planner(root, communicator, level, interests, explicit_categories)
    owner = communicator.owner || communicator.user
    profile = CommunicatorProfile.for(communicator: communicator)

    plan = Boards::StructurePlanner.new(
      level: level,
      profile: profile,
      interests: interests,
      explicit_categories: explicit_categories,
      user: owner,
    ).call

    robust_root = Boards::RobustSets.find_root(plan.core_template)
    if robust_root
      seed_set_interests = collect_seed_set_interests(plan)
      Boards::SeededSetCloner.new(
        robust_root, communicator: communicator,
        interests: seed_set_interests, root: root,
        explicit_categories: explicit_categories,
        # Clone the authored core set INTACT. Excluding "unplanned" seed pages
        # used to strip their sub-boards while leaving the root's folder tiles
        # behind — dead tiles that open nothing (More/School/Time/Describe).
        exclude_fringe: [],
      ).call
    end

    add_fringe_pages_within_grid!(root, communicator, owner, profile, plan)
  end

  def collect_seed_set_interests(plan)
    plan.fringe_pages
      .select { |p| p[:source] == :seed_set }
      .flat_map { |p| p[:interests] || [] }
  end

  # The authored core board fills its grid, with a few intentional empty cells.
  # Board#add_image drops a new tile into the first open cell and only starts a
  # NEW row once the grid is full (see BoardsHelper#next_available_cell). So
  # adding one folder tile per fringe page overflows the authored grid onto a
  # stray extra row — the "85th tile" on a 7x12 (84-cell) Core 84 board.
  #
  # Cap the top-level folder tiles we add to the number of open cells. Pages we
  # can't fit fold their interests into the single "My Favorites" catch-all
  # (one tile, deduped) so nothing the child asked for is dropped — it just
  # lands in Favorites instead of its own page.
  def add_fringe_pages_within_grid!(root, communicator, owner, profile, plan)
    root.reload
    open_cells = root_open_cells(root)

    # Seed-set pages already live in the clone; they need no new tile. Only
    # prebuilt/AI pages add a top-level folder. Interest-bearing pages first so
    # a nearly-full grid still gets the pages the child actually asked for.
    new_pages = plan.fringe_pages
      .reject { |p| p[:source] == :seed_set }
      .sort_by { |p| (p[:interests] || []).any? ? 0 : 1 }

    catch_all = Array(plan.catch_all_interests).dup

    # The total tiles we add (standalone pages + a possible My Favorites) must
    # fit the open cells. We need a My Favorites cell whenever something will
    # be left over — an initial catch-all, OR more pages than will fit. Reserve
    # that cell up front so a page can't claim it and push Favorites onto a
    # stray new row.
    needs_favorites = catch_all.any? || new_pages.size > open_cells
    max_pages = open_cells - (needs_favorites ? 1 : 0)
    max_pages = 0 if max_pages.negative?

    placed = 0
    new_pages.each do |page_plan|
      if placed < max_pages && add_single_fringe_page!(root, communicator, owner, profile, page_plan)
        placed += 1
      else
        catch_all.concat(Array(page_plan[:interests]))
      end
    end

    add_to_favorites!(root, communicator, catch_all) if catch_all.any?
  end

  # Adds one fringe page as a top-level folder tile. Returns true only when a
  # tile was actually added, so the caller decrements its grid budget for real
  # placements only (an AI page that falls back to Favorites for lack of
  # credits adds no tile and returns false).
  def add_single_fringe_page!(root, communicator, owner, profile, page_plan)
    case page_plan[:source]
    when :prebuilt     then clone_one_prebuilt_page!(root, owner, page_plan)
    when :ai_generated then generate_one_ai_page!(root, communicator, owner, profile, page_plan)
    else false
    end
  end

  def clone_one_prebuilt_page!(root, owner, page_plan)
    fringe_source = Boards::FringeTemplates.find(page_plan[:name])
    return false unless fringe_source

    cloned = fringe_source.clone_with_images(owner.id)
    return false unless cloned

    cloned.settings = (cloned.settings || {}).merge("builder_child" => true)
    cloned.save!

    add_folder_tile!(root, owner, page_plan[:name], cloned.id)

    Array(page_plan[:interests]).each { |word| add_interest_to_board(owner, cloned, word) }
    true
  end

  # Returns true when an AI page tile was added; false when it fell back (no
  # credits, or generation failed) so the caller folds the interests into My
  # Favorites instead.
  def generate_one_ai_page!(root, communicator, owner, profile, page_plan)
    return false unless CreditService.can_spend?(owner, feature_key: "ai_board_page")

    blueprint = Boards::AiPageGenerator.new(
      interests: page_plan[:interests],
      profile: profile,
    ).call

    build_fringe_from_blueprint!(root, owner, communicator, blueprint)
    CreditService.spend!(owner, feature_key: "ai_board_page")
    true
  rescue Boards::AiPageGenerator::GenerationError => e
    Rails.logger.warn "[BuildBoardSetJob] AI page generation failed for #{page_plan[:name]}: #{e.message}"
    false
  end

  # Open cells on the authored core grid before a new tile would spill onto a
  # fresh row — mirrors BoardsHelper#next_available_cell's placement rule
  # (fill gaps in the existing rows first, only then start a new row).
  def root_open_cells(board, screen_size = "lg")
    board.update_board_layout(screen_size)
    grid = board.layout[screen_size] || {}
    return 0 if grid.empty?

    columns = board.get_number_of_columns(screen_size)
    occupied = []
    max_row = 0
    grid.each_value do |cell|
      x = cell["x"] || 0
      y = cell["y"] || 0
      w = cell["w"] || 1
      h = cell["h"] || 1
      h.times { |dy| w.times { |dx| occupied << [x + dx, y + dy] } }
      max_row = [max_row, y + h - 1].max
    end

    [(columns * (max_row + 1)) - occupied.uniq.size, 0].max
  end

  def build_fringe_from_blueprint!(root, owner, communicator, blueprint)
    fringe = Board.new(name: blueprint[:name], user: owner)
    fringe.board_type = "static"
    fringe.assign_parent
    fringe.voice = VoiceService.normalize_voice(communicator.voice)
    fringe.generate_unique_slug
    fringe.settings = (fringe.settings || {}).merge("builder_child" => true)
    fringe.save!

    blueprint[:tiles].each do |tile|
      image = resolve_or_create_image(owner, tile[:label])
      fringe.add_image(image.id)
      generate_art_if_blank(owner, image, fringe)
    end

    add_folder_tile!(root, owner, blueprint[:name], fringe.id)

    fringe
  end

  def add_to_favorites!(root, communicator, words)
    return if words.blank?

    owner = communicator.owner || communicator.user
    root.reload

    favorites = root.board_images
      .joins("JOIN boards ON boards.id = board_images.predictive_board_id")
      .where("LOWER(boards.name) = ?", "my favorites")
      .first&.then { |bi| Board.find_by(id: bi.predictive_board_id) }

    unless favorites
      favorites = Board.new(name: "My Favorites", user: owner)
      favorites.board_type = "static"
      favorites.assign_parent
      favorites.voice = VoiceService.normalize_voice(communicator.voice)
      favorites.generate_unique_slug
      favorites.settings = (favorites.settings || {}).merge("builder_child" => true)
      favorites.save!

      add_folder_tile!(root, owner, "My Favorites", favorites.id)
    end

    words.each do |word|
      add_interest_to_board(owner, favorites, word)
    end
  end

  def add_interest_to_board(owner, board, word)
    board.reload
    existing = board.board_images.map { |bi| bi.label.to_s.downcase }
    return if existing.include?(word.to_s.downcase)

    image = resolve_or_create_image(owner, word)
    board.add_image(image.id)
    generate_art_if_blank(owner, image, board)
  end

  # Prefer an art-bearing image so category folder tiles (Animals, Music, …)
  # and routed interests render with a picture by default instead of blank.
  def resolve_or_create_image(owner, label)
    Boards::ImageResolver.resolve(label, owner: owner)
  end

  # Adds a category folder tile linking to `predictive_board_id`. Resolves an
  # art-bearing image for `name`, then pins the tile text to `name` — the art
  # image may be stored under different casing ("animals"), and BoardImage's
  # set_defaults derives the label from the image, so the curated folder name
  # ("Animals") is restored explicitly.
  def add_folder_tile!(root, owner, name, predictive_board_id)
    image = resolve_or_create_image(owner, name)
    tile = root.add_image(image.id)
    tile&.update!(predictive_board_id: predictive_board_id, label: name, display_label: name)
    tile
  end

  def generate_art_if_blank(owner, image, board)
    return if image.display_tile_url(owner).present?
    return if image.docs.any? { |doc| [User::DEFAULT_ADMIN_ID, owner.id].include?(doc.user_id) }

    GenerateImagesJob.perform_async([image.id], board.id)
  end

  def generate_preview!(root)
    root.reload
    root.generate_previews
    # In production the CDN path builds the URL without request context;
    # in dev/test the Disk service needs ActiveStorage::Current.url_options
    # which isn't available inside a Sidekiq job. The preset URL is a
    # nice-to-have cache — preview_image_url resolves live on every API call.
    root.update_preset_display_image_url(root.preview_image_url) if root.preview_image.attached?
  rescue ArgumentError => e
    raise unless e.message.include?("url_options")
  end

  # Legacy path: backward-compatible with direct template keys (core-60, core-84, home, etc.)
  def build_legacy(root, communicator, template, interests, explicit_categories)
    robust_root = Boards::RobustSets.find_root(template)

    if robust_root
      Boards::SeededSetCloner.new(
        robust_root, communicator: communicator,
        interests: interests, root: root,
        explicit_categories: explicit_categories,
      ).call
    else
      owner = communicator.owner || communicator.user
      assembler = Boards::BlueprintAssembler.new(
        template:  template,
        interests: interests,
        user:      owner,
        explicit_categories: explicit_categories,
      )
      blueprint = assembler.call

      Boards::BoardTreeBuilder.new(
        blueprint, communicator: communicator, root: root,
      ).call
    end
  end
end
