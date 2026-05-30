# Seed the starter boards used by the MySpeak onboarding wizard
# (POST /api/v1/onboarding/myspeak) and the board picker fed by
# GET /api/public_boards?myspeak=true.
#
# Each board is tagged "myspeak" so it shows up in
# Board.myspeak_public_boards, and is populated with a starter set of
# tiles so the picker grid in the wizard renders real previews.
#
# Idempotent — safe to re-run. Per-board:
#   * upserts by slug
#   * ensures the "myspeak" tag is present
#   * adds any starter tile labels that aren't already on the board
#
# Adding tiles enqueues GenerateImagesJob for any tiles whose Image
# doesn't yet have a display doc, so run this in an environment where
# Sidekiq workers can drain (or expect the jobs to queue up). See
# Board#find_or_create_images_from_word_list.
#
# Run:
#   bin/rails runner db/seeds/myspeak_starter_boards.rb
#
# Or load from db/seeds.rb:
#   load Rails.root.join("db/seeds/myspeak_starter_boards.rb")

admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || User.where(role: "admin").order(:id).first
abort "No admin user found (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID})." unless admin

starters = [
  {
    slug: "myspeak-basics",
    name: "Basic Needs",
    description: "Core daily words: yes, no, more, help, hurt, all done.",
    category: "welcome",
    tiles: ["Yes", "No", "More", "Help", "Hurt", "All done"],
  },
  {
    slug: "myspeak-feelings",
    name: "Feelings",
    description: "Quick feeling words: happy, sad, mad, scared, tired, calm.",
    category: "welcome",
    tiles: ["Happy", "Sad", "Mad", "Scared", "Tired", "Calm"],
  },
  {
    slug: "myspeak-social",
    name: "Out & About",
    description: "Out-and-about words: hi, bye, please, thank you, my name is, I need.",
    category: "welcome",
    tiles: ["Hi", "Bye", "Please", "Thank you", "My name is", "I need"],
  },
  {
    slug: "myspeak-food",
    name: "Food & Drink",
    description: "Meal-time words: hungry, thirsty, snack, water, milk, done.",
    category: "welcome",
    tiles: ["Hungry", "Thirsty", "Snack", "Water", "Milk", "Done"],
  },
  {
    slug: "myspeak-school",
    name: "School Day",
    description: "School-day words: bathroom, break, finished, question, help, ready.",
    category: "welcome",
    tiles: ["Bathroom", "Break", "Finished", "Question", "Help", "Ready"],
  },
]

starters.each do |attrs|
  board = Board.find_by(slug: attrs[:slug]) || Board.new(slug: attrs[:slug])
  board.assign_attributes(
    name: attrs[:name],
    description: attrs[:description],
    category: attrs[:category],
    user: admin,
    parent: admin,
    predefined: true,
    published: true,
    is_template: false,
    sub_board: false,
    board_type: "board",
  )
  board.add_tag("myspeak")
  board.save!

  existing_labels = board.board_images.pluck(:label).compact.map(&:downcase)
  missing_tiles = attrs[:tiles].reject { |t| existing_labels.include?(t.downcase) }

  if missing_tiles.any?
    board.find_or_create_images_from_word_list(missing_tiles)
  end

  puts "[myspeak-starter] ok: #{board.slug} (id=#{board.id}, tiles=#{board.board_images.count}, tags=#{board.tags.inspect})"
end
