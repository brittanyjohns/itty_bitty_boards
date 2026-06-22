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
# The whole set counts as ONE board against the user's limit: the cloned root is
# marked settings["builder_root"], every other cloned/created board
# settings["builder_child"] (excluded from User#countable_board_count), exactly
# like Boards::BoardTreeBuilder.
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
    def initialize(source_root, communicator:, interests: [], favorite_root: true, root: nil, explicit_categories: {}, exclude_fringe: [])
      @source_root          = source_root
      @communicator         = communicator
      @owner                = communicator.owner || communicator.user
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
      raise CloneError, "communicator has no owning user" unless @owner
      raise CloneError, "no source root board" if @source_root.nil?

      ActiveRecord::Base.transaction do
        @map = clone_all(collect_source_boards(@source_root))
        rewire_predictive_links!
        mark_builder_settings!

        root = @map.fetch(@source_root.id)
        attach_root_to_communicator(root) unless adopted_root?
        route_interests!(root)
        # clone_with_images leaves the in-memory clones with a stale
        # board_images_count / association cache; hand back a fresh root.
        root.reload
      end
    end

    private

    def adopted_root?
      @root.present?
    end

    # BFS over predictive_board_id links from the root, bounded to MAX_DEPTH and
    # cycle-safe (visited set). A board reachable twice is collected once. Root
    # is first in the returned list.
    def collect_source_boards(root)
      visited = {}
      ordered = []
      queue   = [[root, 0]]

      until queue.empty?
        board, depth = queue.shift
        next if board.nil? || visited[board.id]
        next if board.id != root.id && excluded_fringe?(board)

        visited[board.id] = true
        ordered << board
        next if depth >= MAX_DEPTH

        board.board_images.where.not(predictive_board_id: nil).each do |bi|
          sub = Board.find_by(id: bi.predictive_board_id)
          queue << [sub, depth + 1] if sub
        end
      end

      ordered
    end

    def excluded_fringe?(board)
      return false if @exclude_fringe.empty?

      @exclude_fringe.include?(board.name.to_s.strip.downcase)
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
            board
          end
        raise CloneError, "failed to clone source board #{src.id}" if cloned.nil?

        map[src.id] = cloned
      end
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
      # win on conflict; display_follows_preview mirrors clone_with_images.
      root.settings = (src.settings || {})
        .except(Boards::RobustSets::ROOT_MARKER, Boards::RobustSets::SLUG_MARKER)
        .merge(root.settings || {})
        .merge("display_follows_preview" => true)
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
          image = Image.find_by(label: image.label, user_id: target.user_id) if image.user_id == target.user_id
        else
          image = Image.find_by(label: image.label, user_id: [nil, target.user_id, User::DEFAULT_ADMIN_ID])
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
        new_board_image.set_labels
        new_board_image.display_label = board_image.display_label
        new_board_image.voice = board_image.voice
        new_board_image.predictive_board_id = board_image.predictive_board_id
        new_board_image.audio_url = board_image.audio_url
        new_board_image.save!

        # BoardImage#set_defaults (before_create) derives label from the image,
        # so an upgraded art image stored under different casing ("people") would
        # rename the tile. Restore the AUTHORED tile text ("People") post-save.
        if new_board_image.label != board_image.label || new_board_image.display_label != board_image.display_label
          new_board_image.update_columns(label: board_image.label, display_label: board_image.display_label)
        end
      end
    end

    # clone_with_images copies predictive_board_id verbatim, so a cloned folder
    # tile points at the SOURCE sub-board. Translate every pointer to the cloned
    # counterpart via the map. A pointer that leaves the set (out of depth, or a
    # cycle target we didn't collect) is nulled — never leave a user tile opening
    # an admin-owned board.
    def rewire_predictive_links!
      @map.each_value do |cloned|
        cloned.board_images.where.not(predictive_board_id: nil).find_each do |bi|
          target = @map[bi.predictive_board_id]
          bi.update!(predictive_board_id: target&.id)
        end
      end
    end

    # Root counts as one board; every other board in the set is excluded from
    # User#countable_board_count. Same markers Boards::BoardTreeBuilder sets.
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
        fringe   = category && fringe_by_name[category.to_s.downcase]
        fringe ? add_interest_to_board(fringe, word) : unrouted << word
      end

      return if unrouted.empty?

      favorites = fringe_by_name[FAVORITES_NAME.downcase] || create_favorites_board!(root)
      unrouted.each { |word| add_interest_to_board(favorites, word) }
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
      favorites.voice = VoiceService.normalize_voice(@communicator.voice)
      favorites.generate_unique_slug
      favorites.settings = (favorites.settings || {}).merge("builder_child" => true)
      favorites.save!

      folder_tile = root.add_image(resolve_or_create_image(FAVORITES_NAME).id)
      # Pin the tile text to FAVORITES_NAME — an art image may be stored under
      # different casing and BoardImage#set_defaults derives label from it.
      folder_tile&.update!(predictive_board_id: favorites.id,
                           label: FAVORITES_NAME, display_label: FAVORITES_NAME)
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
