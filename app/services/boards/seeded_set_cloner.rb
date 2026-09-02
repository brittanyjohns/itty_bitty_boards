# app/services/boards/seeded_set_cloner.rb
#
# Builds a per-user "robust vocabulary set" for the Board Builder by DEEP-CLONING
# a pre-seeded, admin-owned linked board set (a root core board + fringe category
# pages, linked via BoardImage#predictive_board_id) and routing a child's
# interest words into the cloned fringe pages.
#
# Why clone (not rebuild from labels): cloning preserves the authored grid
# layout, core-tile borders, and part_of_speech colors of the seeded set, which a
# rebuild-from-image_ids (Boards::BoardTreeBuilder) would drop.
#
# The cloned root is marked settings["builder_root"] and every other
# cloned/created board settings["builder_child"], exactly like
# Boards::BoardTreeBuilder — which is what makes the set show up in listings as
# its root rather than as thirty pages. It is NOT a cap exemption: every board
# in the set counts against the user's board_limit (#796), which is why the
# Board Builder reserves room for the whole set before it starts.
#
#   root = Boards::SeededSetCloner.new(
#     source_root_board, communicator: child, interests: ["apple", "grandma"]
#   ).call
#
# Mirrors the normalization/dedup/cap and interest-routing conventions of
# Boards::BlueprintAssembler, but operates on persisted Board records.
module Boards
  class SeededSetCloner
    MAX_DEPTH      = 2 # mirror Boards::BoardTreeBuilder — root + 2 levels
    MAX_INTERESTS  = Boards::InterestWords::MAX_INTERESTS
    FAVORITES_NAME = "My Favorites"

    class CloneError < StandardError; end

    # Normalized interests, exposed so the caller can persist them on the
    # communicator (same contract as BlueprintAssembler#interests).
    attr_reader :interests

    # `root:` (optional) is an ADOPTED root: a board the caller already created
    # (named, parented, slugged, marked builder_root, attached to the
    # communicator) — the async path, where BuildBoardSetJob fills in the set
    # under the root the controller returned with status "building_board".
    # When a root is adopted, the source root's CONTENT (tiles, layout columns)
    # is cloned INTO it instead of dup-ing a fresh board, and the caller owns
    # the ChildBoard attach/favorite.
    #
    # `communicator:` is OPTIONAL — a set can be cloned for a user with no
    # communicator at all and assigned later. Without one there's no ChildBoard
    # attach and the voice falls back to the owner's default. Pass `owner:`
    # explicitly in that case; with a communicator it's derived as before.
    def initialize(source_root, communicator: nil, owner: nil, interests: [], favorite_root: true, root: nil, explicit_categories: {}, exclude_fringe: [])
      @source_root          = source_root
      @communicator         = communicator
      @owner                = owner || communicator&.owner || communicator&.user
      @interests            = normalize_interests(interests)
      @favorite_root        = favorite_root
      @root                 = root
      @explicit_categories  = explicit_categories || {}
      @exclude_fringe       = Array(exclude_fringe).map { |n| n.to_s.strip.downcase }
    end

    # Clones the whole linked set + routes interests in a single transaction so a
    # mid-build failure leaves no orphan boards or dangling ChildBoard (with an
    # adopted root, the rollback strips every fringe board/tile and leaves the
    # bare root for the caller to mark "failed"). Returns the cloned root Board.
    def call
      raise CloneError, "no owning user" unless @owner
      raise CloneError, "no source root board" if @source_root.nil?

      root = ActiveRecord::Base.transaction do
        @map = clone_all(collect_source_boards(@source_root))
        rewire_predictive_links!
        mark_builder_settings!

        cloned_root = @map.fetch(@source_root.id)
        attach_root_to_communicator(cloned_root) if @communicator && !adopted_root?
        route_interests!(cloned_root)
        # clone_with_images leaves the in-memory clones with a stale
        # board_images_count / association cache; hand back a fresh root.
        cloned_root.reload
      end

      unstack_cloned_layouts!
      root
    end

    private

    # A clone must never INHERIT a stacked cell. Both copy paths take the
    # source's layout verbatim, so one seed cell holding two tiles becomes one
    # cell holding two tiles in every set ever built from it — a word hidden
    # behind another, and (because Board#open_grid_cells counts DISTINCT cells)
    # a full grid reporting a free cell that the rest of the build then spends.
    # VocabSets#unstack_layout! keeps the SEED clean; this is the same net for a
    # source that was corrupted after it was seeded.
    #
    # Runs OUTSIDE the transaction above: the repack rewrites layouts and
    # resyncs each board, and a job named on a row must not be pushed from
    # inside the transaction that writes it. Failing here leaves a valid clone —
    # a stacked cell is a defect, not a reason to lose the whole set — so it
    # logs rather than raising, matching how BuildBoardSetJob treats its own
    # post-passes.
    def unstack_cloned_layouts!
      @map.each_value do |board|
        moved = Boards::LayoutRepacker.unstack!(board.reload)
        next if moved.zero?

        Rails.logger.info "[SeededSetCloner] un-stacked #{moved} displaced tile(s) on cloned board #{board.id}"
      end
    rescue => e
      Rails.logger.error "[SeededSetCloner] un-stack failed: #{e.message}"
    end

    def adopted_root?
      @root.present?
    end

    # BFS over predictive_board_id links from the root (shared with
    # Boards::SetCloner via PredictiveLinkSet).
    def collect_source_boards(root)
      Boards::PredictiveLinkSet.collect(root, max_depth: MAX_DEPTH,
                                              exclude: method(:excluded_source?))
    end

    # A source board the walk must not clone. `exclude` is never called for the
    # root itself (Boards::PredictiveLinkSet), so both halves are about PAGES.
    def excluded_source?(board)
      excluded_fringe?(board) || not_a_page?(board)
    end

    def excluded_fringe?(board)
      return false if @exclude_fringe.empty?

      @exclude_fringe.include?(board.name.to_s.strip.downcase)
    end

    # An authored seed page is a plain category board. A board carrying a
    # robust-set ROOT marker, or a builder set's own root/child markers, is
    # something else entirely — another set's home board that a stray folder
    # tile happens to point at — and cloning it drops a SECOND full core board
    # into the set as a page. That page then has no self tile (no nav cell
    # carries its name), so Boards::NavRowSync mints it a way home labelled
    # with the core set's own name, which is the stray "Core 84" tile.
    #
    # Narrow on purpose: this vetoes the WALK, so a legitimate deep page is
    # never in scope — only a board that claims to be the top of a set.
    def not_a_page?(board)
      settings = board.settings
      return false unless settings.is_a?(Hash)

      settings[Boards::RobustSets::ROOT_MARKER].present? ||
        settings["builder_root"].present? ||
        settings["builder_child"].present?
    end

    # Clone each source board for the owner. NO communicator_account arg, so
    # fringe boards don't each get a ChildBoard (only the root is attached, in
    # attach_root_to_communicator). With an adopted root, the source ROOT's
    # content is cloned into the pre-created board instead of dup-ing a new
    # one. Returns { source_board_id => cloned Board }.
    def clone_all(source_boards)
      source_boards.each_with_object({}) do |src, map|
        cloned =
          if adopted_root? && src.id == @source_root.id
            # copy_tiles! already upgrades blank tiles to art for the root.
            clone_into_adopted_root(src)
          else
            board = src.clone_with_images(@owner.id)
            raise CloneError, "failed to clone source board #{src.id}" if board.nil?
            # Board#clone_with_images has no art upgrade, so the seed's fringe
            # sub-boards (and a dup-cloned root) would render their authored
            # tiles blank wherever they point at an art-less library image.
            Boards::ImageResolver.upgrade_board_tiles!(board, owner: @owner)
            strip_template_markers!(board, root: src.id == @source_root.id)
            board
          end
        raise CloneError, "failed to clone source board #{src.id}" if cloned.nil?

        map[src.id] = cloned
      end
    end

    # Board#clone_with_images dups `settings` verbatim, so a clone of a seeded
    # root arrives still claiming to BE that seed: the robust-set catalog
    # markers make it pickable as a template, and `main_board` pins it as the
    # top of a set. clone_into_adopted_root has stripped the first pair since
    # it was written; this is the same rule for the dup-based path, which
    # predates the concern. `main_board` goes only on a PAGE — a dup-cloned
    # root is still a root.
    def strip_template_markers!(board, root:)
      keys = [Boards::RobustSets::ROOT_MARKER, Boards::RobustSets::SLUG_MARKER]
      keys << "main_board" unless root
      settings = board.settings || {}
      return if keys.none? { |k| settings.key?(k) }

      board.update!(settings: settings.except(*keys))
    end

    # The adopted-root version of Board#clone_with_images: copy the source
    # root's presentation attributes and tiles into the board the controller
    # pre-created, leaving the identity its 201 payload already exposed (name,
    # slug, user, parent, voice, status "building_board") untouched.
    def clone_into_adopted_root(src)
      root = @root
      root.board_type            = src.board_type
      root.number_of_columns     = src.number_of_columns
      root.small_screen_columns  = src.small_screen_columns
      root.medium_screen_columns = src.medium_screen_columns
      root.large_screen_columns  = src.large_screen_columns
      root.margin_settings       = src.margin_settings
      root.layout                = src.layout
      root.bg_color              = src.bg_color
      root.language              = src.language
      root.description           = src.description
      # Source settings minus the robust-set catalog markers — a user's copy
      # must never surface as a pickable template (the dup-based clone path
      # predates this concern). The controller's own settings (builder_root)
      # win on conflict; display_image_source mirrors clone_with_images so the
      # adopted root tracks its own freshly-generated preview.
      root.settings = (src.settings || {})
        .except(Boards::RobustSets::ROOT_MARKER, Boards::RobustSets::SLUG_MARKER)
        .merge(root.settings || {})
        .merge("display_image_source" => "preview")
      root.save!

      copy_tiles!(src, root)
      # clone_with_images repoints the owner's pre-existing tiles that target
      # the SOURCE board at the clone; keep that parity for the adopted root.
      UpdateUserBoardsJob.perform_async(root.id, src.id) if src.user_id != root.user_id
      root
    end

    # Mirrors the per-tile copy inside Board#clone_with_images: dup each
    # BoardImage so the authored layout/colors/part_of_speech survive, re-point
    # it at an image the owner can use, and keep predictive_board_id verbatim —
    # rewire_predictive_links! translates the pointers afterwards.
    def copy_tiles!(src, target)
      src.board_images.each do |board_image|
        original_image = board_image.image
        image = original_image
        if image.user_id
          image = Image.by_label(image.label).find_by(user_id: target.user_id) if image.user_id == target.user_id
        else
          image = Image.by_label(image.label).find_by(user_id: [nil, target.user_id, User::DEFAULT_ADMIN_ID])
        end
        image ||= Image.create(label: original_image.label, user_id: target.user_id)

        # The seed often points folder tiles (Animals, People, Feelings…) and
        # some core words at a blank, art-less Image for that label. When the
        # resolved image has no art, upgrade to a curated art-bearing image for
        # the same label so the tile isn't blank. Only ever blank -> art, never
        # the reverse (a tile that already has art is left untouched).
        unless Boards::ImageResolver.art?(image)
          arted = Boards::ImageResolver.resolve(original_image.label, owner: @owner)
          image = arted if Boards::ImageResolver.art?(arted)
        end

        new_board_image = board_image.dup
        new_board_image.board_id = target.id
        new_board_image.image_id = image.id
        # Drop only the text-tile Doc pointer — see BoardImage#cloned_tile_data.
        new_board_image.data = board_image.cloned_tile_data
        new_board_image.set_labels
        # Fold, don't copy — a seed board's casing is defaulted text, and copying
        # it verbatim is what propagated the seeds' Title Case into every built
        # set. Doors ("Food") keep their capital.
        intended_display_label = new_board_image.cloned_display_label_from(board_image)
        new_board_image.display_label = intended_display_label
        new_board_image.voice = board_image.voice
        new_board_image.predictive_board_id = board_image.predictive_board_id
        new_board_image.audio_url = board_image.audio_url
        new_board_image.save!

        # BoardImage#set_defaults (before_create) derives label from the image,
        # so an upgraded art image stored under different casing ("people") would
        # rename the tile. Restore the intended tile text post-save — the folded
        # display text, not the source's, or this would undo the fold above.
        if new_board_image.label != board_image.label || new_board_image.display_label != intended_display_label
          new_board_image.update_columns(label: board_image.label, display_label: intended_display_label)
        end
      end
    end

    # Translate every cloned folder tile's pointer to its cloned counterpart.
    # A pointer that leaves the set (out of depth, or a cycle target we didn't
    # collect) is nulled — never leave a user tile opening an admin-owned board.
    # (Shared with Boards::SetCloner via PredictiveLinkSet.)
    def rewire_predictive_links!
      Boards::PredictiveLinkSet.rewire!(@map, out_of_set: :null)
    end

    # Marks the set's root and its pages so listings show the set as one entry.
    # Not a cap exemption — every board counts (#796). Same markers
    # Boards::BoardTreeBuilder sets.
    def mark_builder_settings!
      @map.each do |src_id, cloned|
        key = (src_id == @source_root.id) ? "builder_root" : "builder_child"
        cloned.settings = (cloned.settings || {}).merge(key => true)
        cloned.save!
      end
    end

    # Mirror Boards::BoardTreeBuilder#attach_root_to_communicator — favorite the
    # root so the wizard lands on it. No ChildBoard for fringe boards.
    def attach_root_to_communicator(root)
      child_board = @communicator.child_boards.create!(board: root, created_by_id: @owner&.id)
      child_board.update!(favorite: true) if @favorite_root
      child_board
    end

    # Route each interest into the cloned fringe board its category maps to;
    # anything with no matching fringe lands in a "My Favorites" fringe (existing
    # one if the set has it, else created and linked from the root). Nothing the
    # user typed is ever dropped.
    def route_interests!(root)
      return if @interests.empty?

      root = Board.find(root.id) # fresh — for correct tile positions
      fringe_by_name = cloned_fringe_by_name
      unrouted = []

      @interests.each do |word|
        category = @explicit_categories[word] || Boards::InterestCategories.category_for(word)
        fringe   = category && fringe_for_category(category, fringe_by_name)
        fringe ? add_interest_to_board(fringe, word) : unrouted << word
      end

      return if unrouted.empty?

      favorites = fringe_by_name[FAVORITES_NAME.downcase] || create_favorites_board!(root)
      # create_favorites_board! returns nil only when the folder tile could not
      # be placed at all. Leftovers stay unrouted rather than overflowing.
      return unless favorites

      unrouted.each { |word| add_interest_to_board(favorites, word) }
    end

    # Match an interest's category to a cloned fringe board. Some
    # InterestCategories names differ from the seed page they belong to
    # ("Family & People" -> "People", "Health & Body" -> "Body"); the
    # StructurePlanner counts those as seed-set interests, so without the alias
    # they'd miss the cloned People/Body board and fall through to My Favorites
    # — spawning an extra top-level folder tile the home grid didn't budget for.
    def fringe_for_category(category, fringe_by_name)
      fringe_by_name[category.to_s.downcase] ||
        fringe_by_name[Boards::StructurePlanner::CATEGORY_SEED_ALIASES[category].to_s.downcase]
    end

    # Cloned non-root boards keyed by normalized name, freshly reloaded so their
    # board_images_count/association reflect the clone. Fringe board names are
    # authored to match Boards::InterestCategories labels (see the seed-format
    # README), so "Food" routing lands in the cloned "Food" board.
    def cloned_fringe_by_name
      @map.each_with_object({}) do |(src_id, cloned), index|
        next if src_id == @source_root.id

        fresh = Board.find(cloned.id)
        index[fresh.name.to_s.strip.downcase] = fresh
      end
    end

    # Dedupe (case-insensitively) against what's already on the board, then add.
    # reload keeps the counter cache / labels fresh across repeated adds.
    def add_interest_to_board(board, word)
      board.reload
      existing = board.board_images.map { |bi| bi.label.to_s.downcase }
      return if existing.include?(word.to_s.downcase)

      image = resolve_or_create_image(word)
      board.add_image(image.id)
      generate_art_if_blank(image, board)
    end

    # A novel interest word (no existing public/admin art) clones in blank; queue
    # AI art so it fills in "later", matching Board#find_or_create_images_from_word_list
    # (board.rb:900/905). Words that resolved to existing art are skipped, so we
    # never pay to regenerate something we already have.
    def generate_art_if_blank(image, board)
      return if image.display_tile_url(@owner).present?
      return if image.docs.any? { |doc| [User::DEFAULT_ADMIN_ID, @owner.id].include?(doc.user_id) }

      GenerateImagesJob.perform_async([image.id], board.id)
    end

    # Create a "My Favorites" fringe owned by the user, marked builder_child so
    # it doesn't count against the limit, and link it from the root via a folder
    # tile + predictive_board_id (mirrors the assembler/tree-builder pattern).
    def create_favorites_board!(root)
      favorites = Board.new(name: FAVORITES_NAME, user: @owner)
      favorites.board_type = "static"
      favorites.assign_parent
      favorites.voice = VoiceService.normalize_voice(@communicator&.voice || @owner.voice)
      favorites.generate_unique_slug
      favorites.settings = (favorites.settings || {}).merge("builder_child" => true)
      favorites.save!

      # Boards::FolderPlacer picks the cell: a real open cell on the home grid,
      # else the set's "More" drawer. The authored Core 60/84 grids are full, so
      # this used to be skipped outright and the child's leftover words never
      # surfaced anywhere.
      placement = Boards::FolderPlacer.place!(root: root, owner: @owner,
                                              name: FAVORITES_NAME, board_id: favorites.id)
      unless placement
        Rails.logger.warn "[SeededSetCloner] root #{root.id}: could not place My Favorites; leftover interests not surfaced"
        favorites.destroy
        return nil
      end

      favorites
    end

    # Prefer an art-bearing image (shared with BuildBoardSetJob) so folder tiles
    # and routed interests render with a picture by default instead of blank.
    def resolve_or_create_image(label)
      Boards::ImageResolver.resolve(label, owner: @owner)
    end

    # Normalization lives in Boards::InterestWords (shared with the assembler
    # and the controller, which persists the list and feeds BuildBoardSetJob).
    def normalize_interests(list)
      Boards::InterestWords.normalize_list(list, max: MAX_INTERESTS)
    end
  end
end
