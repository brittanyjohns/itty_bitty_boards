namespace :keyboard_boards do
  desc "Seed the predefined keyboard template boards (ABC + QWERTY). Idempotent."
  task seed: :environment do
    load Rails.root.join("db/seeds/keyboard_boards.rb")
  end
end
