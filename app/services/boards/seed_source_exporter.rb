module Boards
  # Serializes a Board Builder template board back into the AUTHORED .obf shape
  # that lives in db/seeds/board_builder_sets/ — so an edit made in the board
  # editor can be committed to the seed source instead of being reverted by the
  # next re-seed.
  #
  # Deliberately NOT Boards::ObfExporter. That one serializes a board for a USER
  # to take elsewhere: DB ids, embedded/linked images, sounds, colors, a license —
  # and no part_of_speech, which is the Fitzgerald-key colour the seeds are
  # authored around. The seed files are the minimal opposite: integer button ids,
  # label, part_of_speech, a grid order matrix, and load_board paths.
  #
  # Two things carry across from the seeder and must not drift:
  #   * the board id stays NAMESPACED ("fringe:animals", "core-60:people") —
  #     Board.from_obf upserts on (user_id, obf_id) and both sets seed as the same
  #     admin, so a bare id makes two sets share one board.
  #   * button ids come from data["obf_button_id"], the same stable id
  #     VocabSets.repair_layout! re-pins the authored layout by.
  class SeedSourceExporter
    FORMAT = "open-board-0.1".freeze
    AUTHORED_SCREEN = "lg".freeze

    def initialize(board)
      @board = board
    end

    def call
      {
        "format" => FORMAT,
        "id" => board_obf_id,
        "locale" => board.language.presence || "en",
        "name" => board.name,
        "grid" => grid,
        "buttons" => buttons,
        "images" => [],
        "sounds" => [],
      }
    end

    def to_json_document
      JSON.pretty_generate(call) + "\n"
    end

    # "animals.obf" — the filename this document belongs at inside the seed dir.
    def filename
      base = board_obf_id.to_s.split(":").last.presence || board.name.to_s.parameterize
      "#{base.parameterize}.obf"
    end

    private

    attr_reader :board

    def board_obf_id
      board.obf_id.presence || board.name.to_s.parameterize
    end

    def tiles
      @tiles ||= board.board_images.order(:position).to_a
    end

    # board_image.id => the authored integer id. A tile added in the editor has no
    # obf_button_id yet, so it is handed the next free integer rather than being
    # dropped — that is the whole point of exporting an edited template.
    def authored_ids
      @authored_ids ||= begin
        taken = Set.new
        assigned = {}

        tiles.each do |tile|
          stamped = tile.data.is_a?(Hash) ? tile.data["obf_button_id"] : nil
          next if stamped.blank?
          next unless stamped.to_s.match?(/\A\d+\z/)
          next if taken.include?(stamped.to_i)

          assigned[tile.id] = stamped.to_i
          taken << stamped.to_i
        end

        next_id = 1
        tiles.each do |tile|
          next if assigned.key?(tile.id)

          next_id += 1 while taken.include?(next_id)
          assigned[tile.id] = next_id
          taken << next_id
        end

        assigned
      end
    end

    def buttons
      tiles.map do |tile|
        button = {
          "id" => authored_ids[tile.id],
          "label" => tile.display_label.presence || tile.label,
        }
        button["part_of_speech"] = tile.part_of_speech if tile.part_of_speech.present?
        path = load_board_path(tile)
        button["load_board"] = { "path" => path } if path
        button
      end
    end

    def load_board_path(tile)
      return nil if tile.predictive_board_id.blank?
      return nil if tile.predictive_board_id == tile.board_id

      target = linked_boards[tile.predictive_board_id]
      return nil unless target

      slug = target.obf_id.presence&.split(":")&.last.presence || target.name.to_s.parameterize
      "boards/#{slug.parameterize}.obf"
    end

    def linked_boards
      @linked_boards ||= Board.where(id: tiles.filter_map(&:predictive_board_id).uniq).index_by(&:id)
    end

    # Built from each TILE's own lg cell, not from board.format_grid.
    # format_grid reads the board's denormalized `layout` column and, when that is
    # stale (which a seeded template's often is), falls back to a matrix with no
    # tile id in it at all — so every authored cell would export as null. The
    # per-tile cell is the authoritative position, and reading it has no side
    # effects; Board#open_grid_cells is the alternative and it SAVES.
    #
    # A tile with no lg cell is appended in position order after the laid-out
    # ones rather than dropped, so an export never silently loses a tile.
    def grid
      placed = {}
      unplaced = []

      tiles.each do |tile|
        cell = tile.layout.is_a?(Hash) ? tile.layout[AUTHORED_SCREEN] : nil
        if cell.nil?
          unplaced << tile
        else
          placed[[cell["x"].to_i, cell["y"].to_i]] = authored_ids[tile.id]
        end
      end

      columns = [board.get_number_of_columns(AUTHORED_SCREEN).to_i, 1].max
      rows = placed.keys.map { |(_x, y)| y }.max.to_i + (placed.any? ? 1 : 0)

      order = Array.new(rows) { Array.new(columns, nil) }
      placed.each { |(x, y), id| order[y][x] = id if x < columns && y < rows }

      unplaced.each do |tile|
        slot = next_free_slot(order, columns)
        order << Array.new(columns, nil) if slot.nil?
        x, y = slot || [0, order.size - 1]
        order[y][x] = authored_ids[tile.id]
      end

      { "rows" => order.size, "columns" => columns, "order" => order }
    end

    def next_free_slot(order, columns)
      order.each_with_index do |row, y|
        columns.times { |x| return [x, y] if row[x].nil? }
      end
      nil
    end
  end
end
