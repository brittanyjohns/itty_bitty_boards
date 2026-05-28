# Seed the three starter boards used by the MySpeak onboarding wizard
# (POST /api/v1/onboarding/myspeak). Idempotent — safe to re-run. Image
# tiles are not seeded here; admin can populate via the editor.
#
# Run:
#   bin/rails runner db/seeds/myspeak_starter_boards.rb
#
# Or load from db/seeds.rb:
#   load Rails.root.join("db/seeds/myspeak_starter_boards.rb")

admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || User.where(role: "admin").order(:id).first
abort "No admin user found (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID})." unless admin

STARTERS = [
  {
    slug: "myspeak-basics",
    name: "Basic needs",
    description: "Core daily words: yes, no, more, all done, help, hurt.",
    category: "welcome",
  },
  {
    slug: "myspeak-feelings",
    name: "Feelings & needs",
    description: "Quick feeling and need words: happy, sad, hungry, thirsty, tired, scared.",
    category: "welcome",
  },
  {
    slug: "myspeak-social",
    name: "Out & about",
    description: "Out-and-about words: hi, bye, please, thank you, my name is, I need.",
    category: "welcome",
  },
].freeze

STARTERS.each do |attrs|
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
  board.save!
  puts "[myspeak-starter] #{board.persisted? ? 'ok' : 'failed'}: #{board.slug} (id=#{board.id})"
end
