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

  # Max gestalt phrases promoted to the home-board quick-phrase strip for an
  # early-stage (NLA 1–2) communicator. Capped further by open grid cells.
  PHRASES_STRIP_SIZE = 4

  def perform(root_board_id, communicator_id, level_or_template, interests = [], categories = {}, options = {})
    root = Board.find_by(id: root_board_id)
    unless root
      Rails.logger.error "BuildBoardSetJob: Board with ID #{root_board_id} not found."
      return
    end

    opts = options.is_a?(Hash) ? options : {}
    board_group_id = opts["board_group_id"]

    if root.status == "complete" || root.board_images.exists?
      # Already built (a retry after a partial run, or a stale duplicate enqueue).
      # Still backfill the group membership so a set built before the attach ran
      # — or one whose attach was interrupted — ends up fully grouped. Idempotent.
      attach_set_to_group!(root, board_group_id)
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
      include_phrases = opts["include_phrases"]

      if complexity_level?(level_or_template)
        build_with_structure_planner(root, communicator, level_or_template, interests, explicit_categories, include_phrases)
      else
        build_legacy(root, communicator, level_or_template, interests, explicit_categories)
      end

      # Attach the whole built set (root + every child the build produced —
      # fringe/phrases/favorites/AI pages included) to its builder BoardGroup.
      # This is the single chokepoint after the full set exists, so it catches
      # boards the build services add outside SeededSetCloner/BoardTreeBuilder.
      attach_set_to_group!(root, board_group_id)
      mute_dynamic_tile_names!(root)
      finalize_sub_boards!(root)
      reflow_screen_layouts!(root)
      set_sub_board_previews_from_tiles!(root)
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

  # Phase 2: StructurePlanner-driven hybrid build. Gestalt phrases are no longer
  # a separate build target — every set gets the full core+fringe vocabulary
  # PLUS an integrated "Phrases" layer (Boards::PhrasesPageBuilder), with
  # prominence tuned to the communicator's NLA stage.
  def build_with_structure_planner(root, communicator, level, interests, explicit_categories, include_phrases = nil)
    owner = communicator.owner || communicator.user
    profile = CommunicatorProfile.for(communicator: communicator)

    plan = Boards::StructurePlanner.new(
      level: level,
      profile: profile,
      interests: interests,
      explicit_categories: explicit_categories,
      user: owner,
      include_phrases: include_phrases,
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

    # Build the Phrases layer BEFORE fringe pages so its folder tile (and an
    # early-stage quick-phrase strip) get first claim on the authored grid's
    # open cells; fringe pages then adapt to whatever's left.
    phrases_board = build_phrases_layer!(root, communicator, owner, plan) if plan.phrases_page&.dig(:include)

    add_fringe_pages!(root, communicator, owner, profile, plan, explicit_categories)

    wire_phrase_board!(communicator, owner, phrases_board) if phrases_board
  end

  # Builds the gestalt Phrases sub-tree (Boards::PhrasesPageBuilder), links it
  # from the home board, and — for an early-stage gestalt processor — surfaces a
  # personalized quick-phrase strip on the home board. Returns the Phrases board
  # (for phrase_board wiring), or nil when there's no room / no seeded templates.
  def build_phrases_layer!(root, communicator, owner, plan)
    root.reload
    return nil if root_open_cells(root) < 1

    phrases_board = Boards::PhrasesPageBuilder.new(communicator: communicator, owner: owner).call
    return nil unless phrases_board

    add_folder_tile!(root, owner, Boards::PhrasesPageBuilder::PHRASES_BOARD_NAME, phrases_board.id)

    add_phrase_strip!(root, plan.phrases_page[:stage]) if plan.phrases_page[:prominence] == :strip

    phrases_board
  end

  # Early-stage (gestalt_early?) prominence: surface the top phrases from the
  # stage-recommended function directly on the home board, capped to the open
  # cells left after the Phrases folder + core vocab. Degrades to folder-only
  # when the authored grid has no room — never overflows onto a stray row.
  def add_phrase_strip!(root, stage)
    root.reload
    open = root_open_cells(root)
    return if open < 1

    slug = Boards::GlpTemplates.recommended_for(stage)
    source = slug && Boards::GlpTemplates.find_board(slug)
    return unless source

    # Skip any phrase the home board already carries — e.g. "all done" is both an
    # authored core word AND a Transitions gestalt, so an undeduped strip would
    # add a second "all done" tile. Dedupe by label, then cap to the open cells.
    existing = root.board_images.map { |bi| bi.label.to_s.downcase }
    candidates = source.board_images.order(:position)
      .reject { |bi| existing.include?(bi.label.to_s.downcase) }
      .first([PHRASES_STRIP_SIZE, open].min)
    candidates.each { |bi| root.add_image(bi.image_id) }
  end

  # Folder / dynamic tiles (those that open another board when tapped) shouldn't
  # speak their own label — only word tiles should. Default the BoardImage
  # "mute_name" flag to true on every dynamic tile across the freshly built set
  # (root + linked sub-boards). Display-only flag; update_column skips the audio
  # hook + validations. Idempotent — a no-op once already muted.
  def mute_dynamic_tile_names!(root)
    BoardImage
      .where(board_id: set_board_ids(root))
      .where.not(predictive_board_id: nil)
      .where("predictive_board_id <> board_id")
      .find_each do |bi|
        data = bi.data || {}
        next if data["mute_name"] == true

        bi.update_column(:data, data.merge("mute_name" => true))
      end
  end

  # Every sub-board of a builder set (the builder_child pages — everything in
  # the set EXCEPT the root) is finalized as a real "page":
  #
  #   - settings["freeze_board"] = true so navigating into it doesn't auto-return
  #     to home on the next tap; the frontend's return-home affordance keys off
  #     the freeze_parent_board/board_frozen flags the api_view then exposes.
  #   - re-saved so Board#check_is_sub_board recomputes against the now-wired
  #     predictive_board_id links and sets the sub_board column true. Without this
  #     the children leaked into the `main_boards` scope (their last save happened
  #     before the parent linked them, so sub_board stayed false).
  #
  # The root is intentionally left unfrozen and sub_board=false so it stays a
  # main board. A no-op once already frozen + classified (idempotent on retry).
  # Derive each board's medium/small layout from its authored large layout so
  # the whole set reads well on tablets and phones — the build grows the grid
  # with interest tiles, which can overflow the narrower sm/md grids unless we
  # reflow them width-aware (Boards::ScreenReflow). Runs across root + children.
  def reflow_screen_layouts!(root)
    Board.where(id: set_board_ids(root)).find_each do |board|
      Boards::ScreenReflow.reflow!(board)
    rescue => e
      Rails.logger.error "BuildBoardSetJob #{root.id}: screen reflow failed for board #{board.id}: #{e.message}"
    end
  end

  def finalize_sub_boards!(root)
    child_ids = set_board_ids(root) - [root.id]
    Board.where(id: child_ids).find_each do |board|
      settings = board.settings || {}
      next if settings["freeze_board"] == true && board.sub_board == true

      board.settings = settings.merge("freeze_board" => true)
      board.save! # save recomputes check_is_sub_board => sub_board: true
    end
  end

  # Sub-boards aren't rendered to a PNG preview (GenerateBoardPreviewJob skips
  # builder_child boards). Instead each sub-board's thumbnail is the folder tile
  # that opens it — "whatever board image represents it" wherever that tile lives
  # in the set (the root for top-level fringe pages, the Phrases board for the
  # function pages, etc.). We resolve that tile's image and write it onto the
  # sub-board's denormalized display_image_url COLUMN (the tier-3 seed thumbnail
  # in Board#display_image_url), then purge any stray preview_image so the column
  # wins. update_column skips callbacks so this never re-enqueues a preview.
  def set_sub_board_previews_from_tiles!(root)
    owner = root.user
    ids = set_board_ids(root)
    child_ids = ids - [root.id]
    return if child_ids.empty?

    # The folder tiles (anywhere in the set) that open each child board. If a
    # child is reachable from more than one tile, any one is a fine thumbnail.
    tiles_by_child = BoardImage
      .where(board_id: ids, predictive_board_id: child_ids)
      .includes(:image)
      .index_by(&:predictive_board_id)

    Board.where(id: child_ids).find_each do |child|
      tile = tiles_by_child[child.id]
      next unless tile

      url = tile.tile_image_url(owner)
      next if url.blank?

      child.update_column(:display_image_url, url) unless child.read_attribute(:display_image_url) == url
      child.preview_image.purge if child.preview_image.attached?
    end
  end

  # Attach every board in the built set to its builder BoardGroup, so the set is
  # counted as one Board Set (0 board slots) and cascade-deletes as a unit. The
  # controller already added the root at position 0; this adds the children. The
  # board_group_boards rows are created only when missing, so re-running the job
  # never duplicates them.
  def attach_set_to_group!(root, board_group_id)
    return unless board_group_id

    group = BoardGroup.find_by(id: board_group_id)
    return unless group

    ids = set_board_ids(root)
    existing = group.board_group_boards.where(board_id: ids).pluck(:board_id).to_set
    (ids - existing.to_a).each do |bid|
      group.board_group_boards.create!(board_id: bid)
    end
  end

  # Every board in the just-built set: BFS the predictive_board_id links from the
  # root, bounded in depth and scoped to the owner's boards so a tile pointing at
  # a shared/admin board can't pull it into the sweep.
  def set_board_ids(root, max_depth = 3)
    owner_id = root.user_id
    seen = [root.id]
    frontier = [root.id]
    depth = 0

    while frontier.any? && depth < max_depth
      child_ids = BoardImage.where(board_id: frontier).where.not(predictive_board_id: nil)
        .pluck(:predictive_board_id).uniq
      children = Board.where(id: child_ids, user_id: owner_id).where.not(id: seen).pluck(:id)
      break if children.empty?

      seen.concat(children)
      frontier = children
      depth += 1
    end

    seen
  end

  # The new Phrases board doubles as the communicator's phrase board (the
  # sentence-builder save target + quick-phrase source). Wire it on the
  # communicator and backfill the owner — but only when blank, never clobbering
  # a phrase board the user already picked.
  def wire_phrase_board!(communicator, owner, phrases_board)
    if communicator.settings["phrase_board_id"].blank?
      communicator.update!(settings: (communicator.settings || {}).merge("phrase_board_id" => phrases_board.id))
    end
    if owner.settings["phrase_board_id"].blank?
      owner.update!(settings: (owner.settings || {}).merge("phrase_board_id" => phrases_board.id))
    end
  end

  def collect_seed_set_interests(plan)
    plan.fringe_pages
      .select { |p| p[:source] == :seed_set }
      .flat_map { |p| p[:interests] || [] }
  end

  # Adds the interest-driven fringe pages + a "My Favorites" catch-all to the
  # built home board.
  #
  # The authored core board (Core 60/84) fills its grid completely — there are
  # no reserved cells. Interest-bearing pages and a non-empty My Favorites are
  # therefore allowed to GROW the grid (Board#add_image starts a new row once
  # the grid is full), because a child must never lose a page — or a word — they
  # asked for. Default pages with no interests are NOT grown for: they fill only
  # genuine open cells, so a no-interest build stays one clean page.
  #
  # When the grid grows past the authored rows, the built home board is allowed
  # to scroll (the seed's one-page `disable_scroll` would otherwise clip the
  # grown rows).
  def add_fringe_pages!(root, communicator, owner, profile, plan, explicit_categories = {})
    root.reload
    authored_rows = root.large_screen_rows

    # Seed-set pages already live in the clone; they need no new tile. Only
    # prebuilt/AI pages add a top-level folder. Interest-bearing pages first so
    # they're placed before space-filling default pages.
    new_pages = plan.fringe_pages
      .reject { |p| p[:source] == :seed_set }
      .sort_by { |p| (p[:interests] || []).any? ? 0 : 1 }

    catch_all = Array(plan.catch_all_interests).dup

    new_pages.each do |page_plan|
      has_interests = Array(page_plan[:interests]).any?

      # Default (no-interest) pages only fill real open cells — never grow the
      # grid just to surface empty default content.
      unless has_interests || root_open_cells(root) >= 1
        catch_all.concat(Array(page_plan[:interests]))
        next
      end

      next if add_single_fringe_page!(root, communicator, owner, profile, page_plan)

      catch_all.concat(Array(page_plan[:interests]))
    end

    # Place leftover interests on an existing matching board where one exists,
    # then drop the rest into My Favorites (which grows the grid if it's full).
    catch_all = route_catch_all_to_existing_boards!(root, owner, catch_all, explicit_categories)
    add_to_favorites!(root, communicator, catch_all) if catch_all.any?

    allow_scroll_if_grown!(root, authored_rows)
  end

  # A built set that grew past its authored grid (interest pages / My Favorites
  # on new rows) must scroll, or the native one-page layout clips them. Cloned
  # roots inherit the seed's `disable_scroll`; clear it only when grown.
  def allow_scroll_if_grown!(root, authored_rows)
    root.reload
    return unless root.large_screen_rows > authored_rows
    return unless root.settings&.dig("disable_scroll")

    root.settings["disable_scroll"] = false
    root.save!
  end

  # Before dumping leftover interests into My Favorites, drop each word onto an
  # existing board in the set whose category matches — e.g. a capped seed page
  # (the seed set always clones intact, so the board exists even when the planner
  # didn't budget the word into it) or a sparse AI category whose words were
  # demoted to catch_all. Returns the still-unrouted words.
  def route_catch_all_to_existing_boards!(root, owner, words, explicit_categories)
    return words if words.blank?

    root.reload
    boards_by_name = set_top_level_boards_by_name(root)
    explicit = explicit_categories || {}
    unrouted = []

    words.each do |word|
      category = explicit[word].presence || Boards::InterestCategories.category_for(word)
      board = category && existing_board_for_category(category, boards_by_name)
      if board
        add_interest_to_board(owner, board, word)
      else
        unrouted << word
      end
    end

    unrouted
  end

  # name(downcased) => Board for every board the root's folder tiles open.
  def set_top_level_boards_by_name(root)
    ids = root.board_images.where.not(predictive_board_id: nil).pluck(:predictive_board_id).uniq
    Board.where(id: ids).each_with_object({}) do |board, map|
      map[board.name.to_s.strip.downcase] = board
    end
  end

  # Resolve an InterestCategories name to an existing set board, honoring the
  # seed-page aliases ("Family & People" -> People). Never returns My Favorites —
  # that's the explicit fallback, not a category home.
  def existing_board_for_category(category, boards_by_name)
    name = Boards::StructurePlanner::CATEGORY_SEED_ALIASES[category] || category
    board = boards_by_name[name.to_s.strip.downcase]
    return nil if board.nil? || board.name.to_s.strip.casecmp?("my favorites")

    board
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

    # Board#clone_with_images has no art upgrade, so prebuilt fringe tiles that
    # point at an art-less library image would render blank. Upgrade them to the
    # curated default image for the same label (matches the seed-set clone path).
    Boards::ImageResolver.upgrade_board_tiles!(cloned, owner: owner)

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
  # fresh row. Delegates to Board#open_grid_cells (shared with SeededSetCloner).
  def root_open_cells(board, screen_size = "lg")
    board.open_grid_cells(screen_size)
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
      # My Favorites only ever holds interests the child asked for, so it's
      # always surfaced — growing the grid onto a new row when the authored grid
      # is full (the authored Core 60/84 leaves no reserved cells).
      # add_fringe_pages! clears the home board's one-page `disable_scroll` when
      # growth happens, so the new row isn't clipped.
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
