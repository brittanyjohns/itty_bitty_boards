# MySpeak starter-board maintenance tasks.
#
# The "Core Words" starter board lives as a production row (it is not in
# db/seeds/myspeak_starter_boards.rb), so its recommendation has to be made
# durable by tagging the existing row rather than re-seeding it.
namespace :myspeak do
  RECOMMENDED_TAG = "myspeak-recommended".freeze

  desc "Tag the MySpeak 'Core Words' starter board as recommended (idempotent)"
  task tag_recommended: :environment do
    board = Board.myspeak_public_boards.find_by("LOWER(name) = ?", "core words")

    if board.nil?
      puts "[myspeak:tag_recommended] No public MySpeak board named 'Core Words' found — nothing to do."
      next
    end

    new_tags = board.tags | [RECOMMENDED_TAG]

    if new_tags == board.tags
      puts "[myspeak:tag_recommended] Board ##{board.id} (#{board.name}) already tagged '#{RECOMMENDED_TAG}'. tags=#{board.tags.inspect}"
    else
      board.update!(tags: new_tags)
      puts "[myspeak:tag_recommended] Tagged board ##{board.id} (#{board.name}). tags=#{board.tags.inspect}"
    end
  end
end
