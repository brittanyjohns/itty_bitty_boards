# Seed the predefined Keyboard template boards ("ABC Keyboard" and
# "QWERTY Keyboard"): 26 letter tiles plus two action tiles (Space, Delete).
#
# Tile behavior contract with the frontend (BoardNativeGridPage):
#   * letter tile:  data["tile_type"] == "letter"
#   * action tile:  data["tile_type"] == "action",
#                   data["tile_action"] == "space" | "backspace"
# Future action tiles add new tile_action string values (plus an optional
# data["action_params"] object); keep tile_action a bare string.
#
# Boards seed with published: false ON PURPOSE — frontends without keyboard
# support would render Space/Delete as ordinary speakable word tiles. After
# the frontend keyboard support deploys, flip them live:
#   Board.where(slug: %w[keyboard-abc keyboard-qwerty]).update_all(published: true)
# Re-running this seed never unpublishes an already-published board.
#
# Layouts are authored identically for every screen size (the column count is
# part of what makes it a keyboard), and md/sm are marked as customized
# screens so a later lg edit doesn't reflow away the QWERTY stagger or the
# wide space bar.
#
# Idempotent — safe to re-run. Upserts boards by slug and tiles by label, and
# re-asserts data flags, colors, positions, and layouts on existing tiles.
#
# Run:
#   bin/rails runner db/seeds/keyboard_boards.rb
# Or:
#   bin/rails keyboard_boards:seed

admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || User.where(role: "admin").order(:id).first
abort "No admin user found (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID})." unless admin

vowels = %w[A E I O U]
colors = { letter: "#DBEAFE", vowel: "#FDE68A", action: "#E5E7EB" }
text_color = "#000000"

# 6 columns: A–F / G–L / M–R / S–X / Y Z [Space][Space][Delete][Delete]
abc_tiles = ("A".."Z").each_with_index.map do |ch, i|
  { label: ch, x: i % 6, y: i / 6, w: 1 }
end
abc_tiles << { label: "Space", x: 2, y: 4, w: 2, action: "space" }
abc_tiles << { label: "Delete", x: 4, y: 4, w: 2, action: "backspace" }

# 10 columns: the three staggered QWERTY rows, Delete at the end of the Z
# row, and a wide centered space bar on the bottom row.
qwerty_rows = [%w[Q W E R T Y U I O P], %w[A S D F G H J K L], %w[Z X C V B N M]]
qwerty_tiles = qwerty_rows.each_with_index.flat_map do |row, y|
  row.each_with_index.map { |ch, x| { label: ch, x: x, y: y, w: 1 } }
end
qwerty_tiles << { label: "Delete", x: 7, y: 2, w: 3, action: "backspace" }
qwerty_tiles << { label: "Space", x: 2, y: 3, w: 6, action: "space" }

keyboards = [
  {
    slug: "keyboard-abc",
    name: "ABC Keyboard",
    description: "Spell any word, letter by letter — alphabetical layout with Space and Delete keys.",
    columns: 6,
    tiles: abc_tiles,
  },
  {
    slug: "keyboard-qwerty",
    name: "QWERTY Keyboard",
    description: "Spell any word, letter by letter — familiar QWERTY layout with Space and Delete keys.",
    columns: 10,
    tiles: qwerty_tiles,
  },
]

find_or_create_image = lambda do |label|
  image = Image.find_by(label: label, user_id: admin.id)
  return image if image

  image = Image.new(label: label, user_id: admin.id, part_of_speech: "default")
  # Single letters aren't dictionary words — without this flag ensure_defaults
  # would make a synchronous OpenAI categorization call per tile at seed time.
  image.skip_categorize = true
  image.save!
  image
end

keyboards.each do |attrs|
  board = Board.find_by(slug: attrs[:slug]) || Board.new(slug: attrs[:slug])
  newly_created = board.new_record?
  board.assign_attributes(
    name: attrs[:name],
    description: attrs[:description],
    category: "letters",
    user: admin,
    parent: admin,
    predefined: true,
    is_template: false,
    sub_board: false,
    board_type: "keyboard",
    voice: VoiceService.normalize_voice(board.voice),
    number_of_columns: attrs[:columns],
    small_screen_columns: attrs[:columns],
    medium_screen_columns: attrs[:columns],
    large_screen_columns: attrs[:columns],
  )
  board.published = false if newly_created
  board.settings = (board.settings || {}).merge("custom_screen_layouts" => %w[md sm])
  board.add_tag("keyboard")
  board.save!

  attrs[:tiles].each_with_index do |tile, position|
    color = if tile[:action]
        colors[:action]
      elsif vowels.include?(tile[:label])
        colors[:vowel]
      else
        colors[:letter]
      end
    tile_data = if tile[:action]
        { "tile_type" => "action", "tile_action" => tile[:action] }
      else
        { "tile_type" => "letter" }
      end

    image = find_or_create_image.call(tile[:label])
    board_image = board.board_images.find_by(label: tile[:label])
    unless board_image
      board_image = board.board_images.new(
        image_id: image.id,
        voice: board.voice,
        language: board.language,
        bg_color: color,
        text_color: text_color,
        position: position,
      )
      board_image.skip_initial_layout = true
      board_image.save!
    end

    layout = %w[lg md sm xs xxs].index_with do |_screen|
      { "i" => board_image.id.to_s, "x" => tile[:x], "y" => tile[:y], "w" => tile[:w], "h" => 1 }
    end
    board_image.update!(
      position: position,
      data: (board_image.data || {}).merge(tile_data),
      bg_color: color,
      text_color: text_color,
      layout: layout,
    )
  end

  puts "[keyboard-boards] ok: #{board.slug} (id=#{board.id}, tiles=#{board.board_images.count}, published=#{board.published})"
end
