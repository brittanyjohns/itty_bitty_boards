# app/services/boards/sub_board_thumbnails.rb
module Boards
  # A sub-board's thumbnail is the folder tile that OPENS it — "whatever board
  # image represents it" wherever that tile lives in the set (the root for
  # top-level pages, the Phrases board for the function pages, and so on). The
  # resolved tile image is written to the sub-board's denormalized
  # `display_image_url` COLUMN, the tier-3 seed thumbnail in
  # Board#display_image_url.
  #
  # This exists so a set does NOT queue a Grover render per page. Rendering
  # every sub-board to a PNG means one headless-Chrome run each, on the shared
  # `:default` queue — a 100-page vocabulary set would stall every other job
  # behind it. One indexed query plus an update per child covers the whole set,
  # and the folder tile is arguably the better thumbnail anyway: it is the
  # picture the user already associates with that page.
  #
  # `update_column` skips callbacks, so this never re-enqueues a preview.
  class SubBoardThumbnails
    # board_ids — every board in the set, INCLUDING the root. Tiles are searched
    #   across all of them, since the tile that opens a page often lives on a
    #   sibling rather than the root.
    # purge_previews — drop any PNG a child already has, so the column wins.
    #   True for the Board Builder, whose sub-boards are deliberately never
    #   rendered (GenerateBoardPreviewJob skips builder_child). False for
    #   imports: an imported page is an ordinary board, so if the user edits it
    #   later and earns a real preview, that preview should win.
    def self.apply!(owner:, board_ids:, root_id:, purge_previews: false)
      new(owner: owner, board_ids: board_ids, root_id: root_id, purge_previews: purge_previews).call
    end

    def initialize(owner:, board_ids:, root_id:, purge_previews: false)
      @owner = owner
      @board_ids = Array(board_ids).compact.uniq
      @root_id = root_id
      @purge_previews = purge_previews
    end

    def call
      child_ids = board_ids - [root_id]
      return 0 if child_ids.empty?

      # If a child is reachable from more than one tile, any one is a fine
      # thumbnail.
      tiles_by_child = BoardImage
        .where(board_id: board_ids, predictive_board_id: child_ids)
        .includes(:image)
        .index_by(&:predictive_board_id)

      applied = 0

      Board.where(id: child_ids).find_each do |child|
        tile = tiles_by_child[child.id]
        next unless tile

        url = tile.tile_image_url(owner)
        next if url.blank?

        child.update_column(:display_image_url, url) unless child.read_attribute(:display_image_url) == url
        child.preview_image.purge if purge_previews && child.preview_image.attached?
        applied += 1
      end

      applied
    end

    private

    attr_reader :owner, :board_ids, :root_id, :purge_previews
  end
end
