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
    MAX_INTERESTS  = 12 # mirror Boards::BlueprintAssembler
    FAVORITES_NAME = "My Favorites"

    class CloneError < StandardError; end

    # Normalized interests, exposed so the caller can persist them on the
    # communicator (same contract as BlueprintAssembler#interests).
    attr_reader :interests

    def initialize(source_root, communicator:, interests: [], favorite_root: true)
      @source_root   = source_root
      @communicator  = communicator
      @owner         = communicator.owner || communicator.user
      @interests     = normalize_interests(interests)
      @favorite_root = favorite_root
    end

    # Clones the whole linked set + routes interests in a single transaction so a
    # mid-build failure leaves no orphan boards or dangling ChildBoard. Returns
    # the cloned root Board.
    def call
      raise CloneError, "communicator has no owning user" unless @owner
      raise CloneError, "no source root board" if @source_root.nil?

      ActiveRecord::Base.transaction do
        @map = clone_all(collect_source_boards(@source_root))
        rewire_predictive_links!
        mark_builder_settings!

        root = @map.fetch(@source_root.id)
        attach_root_to_communicator(root)
        route_interests!(root)
        # clone_with_images leaves the in-memory clones with a stale
        # board_images_count / association cache; hand back a fresh root.
        root.reload
      end
    end

    private

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

    # Clone each source board for the owner. NO communicator_account arg, so
    # fringe boards don't each get a ChildBoard (only the root is attached, in
    # attach_root_to_communicator). Returns { source_board_id => cloned Board }.
    def clone_all(source_boards)
      source_boards.each_with_object({}) do |src, map|
        cloned = src.clone_with_images(@owner.id)
        raise CloneError, "failed to clone source board #{src.id}" if cloned.nil?

        map[src.id] = cloned
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
        category = Boards::InterestCategories.category_for(word)
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
      folder_tile&.update!(predictive_board_id: favorites.id)
      favorites
    end

    # Mirror Board#find_or_create_images_from_word_list / BlueprintAssembler:
    # the owner's own image, then a public/admin image, else create. A fresh
    # image starts with no art — acceptable for v1 (blank tile, AI art later).
    def resolve_or_create_image(label)
      word  = normalize_word(label)
      image = @owner.images.find_by(label: word)
      image ||= Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil])
      image ||= Image.create!(label: word, user_id: @owner.id)
      image
    end

    def normalize_interests(list)
      Array(list).map { |s| normalize_word(s) }.reject(&:blank?).uniq.first(MAX_INTERESTS)
    end

    # multi-char words kept as typed, lone "i" -> "I", other single chars lowercased.
    def normalize_word(string)
      word = string.to_s.strip
      return "" if word.blank?
      return "I" if word.casecmp("i").zero?

      word.length > 1 ? word : word.downcase
    end
  end
end
