require "obf"

module BoardsHelper
  def to_obf
    obf_board = OBF::Utils.obf_shell
    obf_board = obf_board.with_indifferent_access
    puts "obf_board: #{obf_board}"
    obf_board[:id] = self.id.to_s
    obf_board[:locale] = "en"
    obf_board[:name] = self.name
    obf_board[:format] = OBF::OBF::FORMAT
    obf_board[:default_layout] = "landscape"
    puts "-- obf -- #{obf_board}"
    # obf_board[:background] = self.background
    # obf_board[:url] = self.url
    # obf_board[:data_url] = self.data_url
    # obf_board[:description_html] = self.description_html
    # obf_board[:protected_content_user_identifier] = self.protected_content_user_identifier
    obf_board[:license] = self.license
    obf_board[:default_locale] = self.default_locale
    obf_board[:label_locale] = self.label_locale
    obf_board[:grid] = self.format_grid
    obf_board[:images] = self.board_images.map(&:to_obf_image_format)
    obf_board[:sounds] = self.board_images.map(&:to_obf_sound_format)
    obf_board[:buttons] = self.board_images.map(&:to_obf_button_format) if self.predictive? || self.category?

    data = obf_board.to_json
    File.open("obf.json", "w") { |file| file.write(data) }
    obf_board
  end

  def format_grid
    new_grid = Hash.new { |hash, key| hash[key] = [] }
    screen_size = "lg"
    columns = large_screen_columns
    board_image_count = board_images.count
    puts "Board Image Count: #{board_image_count}"
    og_grid = print_grid_layout_for_screen_size(screen_size)
    puts "Original Grid: #{og_grid}"
    grid = self.layout[screen_size] || []
    rows = grid.map { |cell| cell["y"] + cell["h"] }.max || 0
    puts "Rows: #{rows} - Columns: #{columns}"
    new_grid = []
    rows.times do |y|
      new_grid << Array.new(columns, nil)
    end
    og_grid.each do |cell|
      x = cell["x"]
      y = cell["y"]
      w = cell["w"]
      h = cell["h"]
      new_grid[y][x] = cell["i"]
      #   (y + 1).upto(y + h - 1) do |yy|
      #     (x + 1).upto(x + w - 1) do |xx|
      #       puts "YY: #{yy} - XX: #{xx}"
      #       new_grid[yy][xx] = cell["i"]
      #     end
      #   end
    end

    result = {}
    result = {
      "rows" => rows,
      "columns" => columns,
      "order" => new_grid,
    }
    result
  end
end
