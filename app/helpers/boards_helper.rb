require "obf"

module BoardsHelper
  def to_obf(viewing_user = nil)
    viewing_user ||= user
    obf_board = OBF::Utils.obf_shell
    obf_board = obf_board.with_indifferent_access
    obf_board[:id] = self.id.to_s
    obf_board[:locale] = "en"
    obf_board[:name] = self.name
    obf_board[:format] = OBF::OBF::FORMAT
    obf_board[:default_layout] = "landscape"

    obf_board[:description_html] = self.description_html
    obf_board[:license] = self.license
    obf_board[:grid] = self.format_grid
    obf_board[:images] = self.board_images.map { |image| image.to_obf_image_format(viewing_user) }
    obf_board[:sounds] = self.board_images.map(&:to_obf_sound_format)
    obf_board[:buttons] = self.board_images.map(&:to_obf_button_format)

    # data = obf_board.to_json
    # File.open("obf.obf", "w") { |file| file.write(data) }
    obf_board
  end

  def to_obz(viewing_user = nil)
    obf_board = to_obf(viewing_user)
    OBF::External.to_obz(obf_board, "new_obz.obz")
    # A .obz file is a zip file containing an .obf file and all the images and sounds referenced by the .obf file.
  end

  def get_number_of_columns(screen_size = "lg")
    case screen_size
    when "sm"
      num_of_columns = self.small_screen_columns > 0 ? self.small_screen_columns : 4
    when "md"
      num_of_columns = self.medium_screen_columns > 0 ? self.medium_screen_columns : 6
    when "lg"
      num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 8
    else
      num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 12
    end
  end

  def to_pdf
    OBF::PDF.from_obf("obf.obf", "obf.pdf")
  end

  def format_grid
    new_grid = Hash.new { |hash, key| hash[key] = [] }
    screen_size = "lg"
    columns = large_screen_columns
    board_image_count = board_images_count
    og_grid = print_grid_layout_for_screen_size(screen_size)
    grid = self.layout[screen_size] || []
    rows = og_grid.map { |cell| cell["y"] + cell["h"] }.max || 0
    new_grid = []
    rows.times do |y|
      new_grid << Array.new(columns, nil)
    end
    og_grid.each do |cell|
      x = cell["x"]
      y = cell["y"]
      w = cell["w"]
      h = cell["h"]
      new_grid[y] ||= []
      new_grid[y][x] = cell["i"].to_i
    end

    result = {}
    result = {
      "rows" => rows,
      "columns" => columns,
      "order" => new_grid,
    }
    result
  end

  def description_html
    if description.nil?
      "<p>This board was created using SpeakAnyWay AAC. You can create your own boards at <a href='https://www.speakanyway.com'>SpeakAnyWay.com</a></p>"
    else
      "<p>#{description}</p>"
    end
  end

  def get_background_color_css
    bg_hex
  end

  def layout_invalid?
    return true if layout.blank?
    return true if layout["lg"] == nil || layout["md"] == nil || layout["sm"] == nil
    return true if layout["lg"].values.any?(&:nil?) || layout["md"].values.any?(&:nil?) || layout["sm"].values.any?(&:nil?)
    return true if layout["lg"]["i"] != id.to_s || layout["md"]["i"] != id.to_s || layout["sm"]["i"] != id.to_s
    return true if layout["lg"]["w"] != 1 || layout["md"]["w"] != 1 || layout["sm"]["w"] != 1
    return true if layout["lg"]["h"] != 1 || layout["md"]["h"] != 1 || layout["sm"]["h"] != 1
    return false
  end

  def set_layouts_for_screen_sizes
    calculate_grid_layout_for_screen_size("sm", true)
    calculate_grid_layout_for_screen_size("md", true)
    calculate_grid_layout_for_screen_size("lg", true)
  end

  def update_layouts_for_screen_sizes
    update_board_layout("sm")
    update_board_layout("md")
    update_board_layout("lg")
  end

  def next_available_cell(screen_size = "lg")
    occupied = Hash.new { |hash, key| hash[key] = [] }
    self.update_board_layout(screen_size)
    grid = self.layout[screen_size] || []
    columns = get_number_of_columns(screen_size)

    # Mark occupied cells
    grid.each do |cell|
      cell_layout = cell[1]
      x, y, w, h = cell_layout.values_at("x", "y", "w", "h")

      x ||= 0
      y ||= 0
      w ||= 1
      h ||= 1

      w.times do |w_offset|
        h.times do |h_offset|
          occupied[y + h_offset] << (x + w_offset)
        end
      end
    end

    # No tiles yet
    return { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } if occupied.empty?

    # Find the last used row
    last_row = occupied.keys.max

    # Find first open spot in the last used row
    # (0...columns).each do |x|
    #   unless occupied[last_row].include?(x)
    #     return { "x" => x, "y" => last_row, "w" => 1, "h" => 1 }
    #   end
    # end

    # Find the first open spot
    (0..last_row).each do |y|
      (0...columns).each do |x|
        unless occupied[y].include?(x)
          return { "x" => x, "y" => y, "w" => 1, "h" => 1 }
        end
      end
    end

    # If last row is full, start a new row
    { "x" => 0, "y" => last_row + 1, "w" => 1, "h" => 1 }
  end

  def broadcast_board_change!(communicator_account_id:, board_id:)
    payload = {
      type: "board.changed",
      board_id: board_id,
      communicator_account_id: communicator_account_id,
      updated_at: Time.current.iso8601,
    }
    ActionCable.server.broadcast("boards:communicator_account:#{communicator_account_id}", payload)
  end

  def broadcast_board_update!
    return if skip_broadcasting
    board_id = self.id.to_s
    ActionCable.server.broadcast(
      "boards:#{board_id}",
      { type: "board.updated", board_id: board_id, version: Time.current.to_i }
    )
  end

  def generate_placeholder_image(text)
    key = text.to_s.strip
    key = "..." if key.blank?

    max_chars_per_line = 10
    max_lines = 3

    # Split into lines
    words = key.split(/\s+/)
    lines = []
    current_line = ""

    words.each do |word|
      test_line = current_line.present? ? "#{current_line} #{word}" : word

      if test_line.length <= max_chars_per_line
        current_line = test_line
      else
        lines << current_line if current_line.present?
        current_line = word
      end
    end

    lines << current_line if current_line.present?

    # Fallback if somehow no lines were built
    lines = [key] if lines.empty?

    # Truncate lines if too many
    final_lines = lines.first(max_lines)
    if lines.length > max_lines
      final_lines[max_lines - 1] = "#{final_lines[max_lines - 1]}..."
    end

    longest_line_length = final_lines.map(&:length).max || 1
    font_size = [[(300.0 / longest_line_length) * 1.8, 80].min, 24].max

    line_height = font_size * 1.2
    start_y = 150 - ((final_lines.length - 1) * line_height) / 2.0

    tspans = final_lines.each_with_index.map do |line, i|
      y = start_y + (i * line_height)
      %(<tspan x="50%" y="#{y}">#{escape_xml(line)}</tspan>)
    end.join

    svg = <<~SVG.strip
      <svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" viewBox="0 0 300 300">
        <rect width="300" height="300" fill="transparent"/>
        <text
          text-anchor="middle"
          font-family="Arial, sans-serif"
          font-size="#{font_size}"
          fill="#000000">
          #{tspans}
        </text>
      </svg>
    SVG

    encoded = Base64.strict_encode64(svg)
    "data:image/svg+xml;base64,#{encoded}"
  end

  def escape_xml(text)
    CGI.escapeHTML(text.to_s)
  end
end
