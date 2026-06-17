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
      else
        build_legacy(root, communicator, level_or_template, interests, explicit_categories)
      end

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
        exclude_fringe: plan.excluded_fringe_pages,
      ).call
    end

    clone_prebuilt_fringe_pages!(root, communicator, plan)
    generate_ai_fringe_pages!(root, communicator, owner, plan, profile)
    add_to_favorites!(root, communicator, plan.catch_all_interests) if plan.catch_all_interests.any?
  end

  def collect_seed_set_interests(plan)
    plan.fringe_pages
      .select { |p| p[:source] == :seed_set }
      .flat_map { |p| p[:interests] || [] }
  end

  def clone_prebuilt_fringe_pages!(root, communicator, plan)
    owner = communicator.owner || communicator.user
    plan.fringe_pages.select { |p| p[:source] == :prebuilt }.each do |page_plan|
      fringe_source = Boards::FringeTemplates.find(page_plan[:name])
      next unless fringe_source

      cloned = fringe_source.clone_with_images(owner.id)
      next unless cloned

      cloned.settings = (cloned.settings || {}).merge("builder_child" => true)
      cloned.save!

      folder_image = resolve_or_create_image(owner, page_plan[:name])
      folder_tile = root.add_image(folder_image.id)
      folder_tile&.update!(predictive_board_id: cloned.id)

      (page_plan[:interests] || []).each do |word|
        add_interest_to_board(owner, cloned, word)
      end
    end
  end

  def generate_ai_fringe_pages!(root, communicator, owner, plan, profile)
    plan.fringe_pages.select { |p| p[:source] == :ai_generated }.each do |page_plan|
      if CreditService.can_spend?(owner, feature_key: "ai_board_page")
        blueprint = Boards::AiPageGenerator.new(
          interests: page_plan[:interests],
          profile: profile,
        ).call

        fringe = build_fringe_from_blueprint!(root, owner, communicator, blueprint)
        CreditService.spend!(owner, feature_key: "ai_board_page")
      else
        add_to_favorites!(root, communicator, page_plan[:interests] || [])
      end
    rescue Boards::AiPageGenerator::GenerationError => e
      Rails.logger.warn "[BuildBoardSetJob] AI page generation failed for #{page_plan[:name]}: #{e.message}"
      add_to_favorites!(root, communicator, page_plan[:interests] || [])
    end
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

    folder_image = resolve_or_create_image(owner, blueprint[:name])
    folder_tile = root.add_image(folder_image.id)
    folder_tile&.update!(predictive_board_id: fringe.id)

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

      folder_image = resolve_or_create_image(owner, "My Favorites")
      folder_tile = root.add_image(folder_image.id)
      folder_tile&.update!(predictive_board_id: favorites.id)
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

  def resolve_or_create_image(owner, label)
    word = Boards::InterestWords.normalize_word(label)
    image = owner.images.find_by(label: word)
    image ||= Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil])
    image ||= Image.create!(label: word, user_id: owner.id)
    image
  end

  def generate_art_if_blank(owner, image, board)
    return if image.display_tile_url(owner).present?
    return if image.docs.any? { |doc| [User::DEFAULT_ADMIN_ID, owner.id].include?(doc.user_id) }

    GenerateImagesJob.perform_async([image.id], board.id)
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
