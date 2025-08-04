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

  COLORS = {
    "white" => "rgb(255, 255, 255)",
    "red" => "rgb(255, 0, 0)",
    "red pink" => "rgb(255, 112, 156)",
    "pinky purple" => "rgb(255, 115, 222)",
    "light red-orange" => "rgb(250, 196, 140)",
    "orange" => "rgb(255, 196, 87)",
    "yellow" => "rgb(255, 234, 117)",
    "yellowy" => "rgb(255, 241, 92)",
    "light yellow" => "rgb(252, 242, 134)",
    "dark green" => "rgb(82, 209, 86)",
    "navy green" => "rgb(149, 189, 42)",
    "green" => "rgb(161, 245, 113)",
    "pale green" => "rgb(196, 252, 141)",
    "strong blue" => "rgb(94, 207, 255)",
    "happy blue" => "rgb(148, 223, 255)",
    "bluey" => "rgb(176, 223, 255)",
    "light blue" => "rgb(194, 241, 255)",
    "dark purple" => "rgb(118, 152, 199)",
    "light purple" => "rgb(208, 190, 232)",
    "brown" => "rgb(153, 79, 0)",
    "dark blue" => "rgb(0, 109, 235)",
    "black" => "rgb(0, 0, 0)",
    "gray" => "rgb(161, 161, 161)",
    "dark orange" => "rgb(255, 108, 59)",
  }

  def get_background_color_css
    color = self.bg_color
    if color.blank?
      color = "white"
    end
    COLORS[color]
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
    # Create a hash to track occupied cells
    occupied = Hash.new { |hash, key| hash[key] = [] }
    self.update_board_layout(screen_size)
    grid = self.layout[screen_size] || []

    # Mark existing cells as occupied
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

    columns = get_number_of_columns(screen_size)

    # Search for the first unoccupied 1x1 cell
    (0..Float::INFINITY).each do |y|
      (0...columns).each do |x|
        unless occupied[y].include?(x)
          return { "x" => x, "y" => y, "w" => 1, "h" => 1 }
        end
      end
    end
  end

  def set_slug
    return unless name.present? && slug.blank?

    slug = name.parameterize
    existing_board = Board.find_by(slug: slug)
    if existing_board
      Rails.logger.warn "Board with slug '#{slug}' already exists. Generating a new slug."
      random = SecureRandom.hex(8)
      slug = "#{slug}-#{random}"
    end
    self.slug = slug
  end
end
