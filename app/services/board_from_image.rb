# app/services/board_from_image.rb
class BoardFromImage
  def self.commit!(import)
    rows = import.guessed_rows || 6
    cols = import.guessed_cols || 8
    board = import.user.boards.create!(
      name: "Imported Board (#{Time.current.to_date})",
      rows: rows, cols: cols, status: :draft,
    )

    grid = Array.new(rows) { Array.new(cols) }
    import.board_cell_candidates.find_each do |c|
      next unless c.row.between?(0, rows - 1) && c.col.between?(0, cols - 1)
      label = c.label_norm.presence || c.label_raw.presence || ""
      next if label.blank?
      grid[c.row][c.col] = label
    end

    grid.each_with_index do |row, r|
      row.each_with_index do |label, c|
        next if label.blank?
        board.board_cells.create!(row: r, col: c, label: label)
      end
    end

    board
  end
end
