# app/services/boards/board_tree_builder.rb
#
# Deterministic backend for the Board Builder. Takes a nested "blueprint"
# (a root board + linked sub-boards) and persists it as real, linked Board
# records, then attaches the root to a communicator (child_account) via a
# ChildBoard join.
#
# A tile is a BoardImage. A tile becomes a *folder* when its
# predictive_board_id points at another board, so "build a set" = create
# boards, add their tiles, and set predictive_board_id on folder tiles. No
# new schema. This is unrelated to BoardGroup / board_group_boards.
#
# Closest reference in the codebase: Board.from_obf + ObzImporter's
# create-then-link two-pass.
#
# Blueprint shape (input contract — image_ids are already resolved):
#
#   { name: "Leo's Home",
#     tiles: [
#       { label: "I",    image_id: 101 },
#       { label: "Food", image_id: 140, children: { name: "Food", tiles: [...] } },
#     ] }
#
# A tile with a `children:` key is a folder; everything else is a leaf.
module Boards
  class BoardTreeBuilder
    # Depth cap lives in exactly ONE place: root + 2 => 3 board levels total.
    # depth 0 = root; build children only when depth < MAX_DEPTH. A folder tile
    # at depth 2 stays a leaf (no child board, no link).
    MAX_DEPTH = 2

    class BuildError < StandardError; end

    def initialize(blueprint, communicator:, favorite_root: false)
      @blueprint     = blueprint.deep_symbolize_keys
      @communicator  = communicator
      @owner         = communicator.owner || communicator.user
      @favorite_root = favorite_root
    end

    # Builds the whole tree in a single transaction so a mid-build failure
    # leaves no orphan boards or dangling ChildBoard. Returns the root Board.
    def call
      raise BuildError, "communicator has no owning user" unless @owner

      ActiveRecord::Base.transaction do
        root = build_board(@blueprint, depth: 0)
        attach_root_to_communicator(root)
        root
      end
    end

    private

    # Depth-first: build the child board first, then point the parent tile's
    # predictive_board_id at it (can't link to a board that doesn't exist yet).
    def build_board(node, depth:)
      board = Board.new(name: node[:name], user: @owner)
      board.board_type = board_type_for(node, depth) # "dynamic" or "static"
      board.assign_parent                            # => parent is the owning User
      board.voice = VoiceService.normalize_voice(@communicator.voice)
      board.generate_unique_slug
      board.save!

      Array(node[:tiles]).each do |tile|
        # add_image resolves the Image and sets label/voice/part-of-speech/
        # colors/layout. It also enqueues a SaveAudioJob via BoardImage's
        # after_create — expected fan-out, runs post-commit.
        board_image = board.add_image(tile[:image_id])
        raise BuildError, "image #{tile[:image_id].inspect} not found" if board_image.nil?

        if tile[:children] && depth < MAX_DEPTH
          child = build_board(tile[:children], depth: depth + 1)
          board_image.update!(predictive_board_id: child.id) # link folder -> child
        end
      end

      board
    end

    def attach_root_to_communicator(root)
      child_board = @communicator.child_boards.create!(board: root, created_by_id: @owner&.id)
      child_board.update!(favorite: true) if @favorite_root
      child_board
    end

    # User-owned boards: use "dynamic" when this board links children, else
    # "static". Both route Board#assign_parent to the owning User (not an Image,
    # which "category"/"predictive" board_types would create).
    def board_type_for(node, depth)
      links_children = depth < MAX_DEPTH && Array(node[:tiles]).any? { |t| t[:children] }
      links_children ? "dynamic" : "static"
    end
  end
end
