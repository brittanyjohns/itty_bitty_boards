namespace :audits do
  desc "Create a audits for account"
  task create_word_events: :environment do
    communicator_account = ChildAccount.find(33)
    user = communicator_account.user
    board_to_use = Board.predefined.sample
    # new_name = "#{user.name}'s #{board_to_use.name} Board"
    # new_board = board_to_use.clone_with_images(user.id, new_name)
    # communicator_account.child_boards.create!(board: new_board)

    words = board_to_use.board_images.map(&:label).uniq
    puts "Creating word events for communicator account #{communicator_account.username}: word count: #{words.count}"
    words.each do |word|
      puts "Creating word event for word: #{word}"
      payload = {
        word: word,
        previous_word: words.sample,
        timestamp: FFaker::Time.between_dates(from: Date.today - 45, to: Date.today - 31, period: :afternoon, format: :default),
        user_id: user.id,
        board_id: board_to_use.id,
        team_id: user.current_team_id,
        child_account_id: communicator_account.id,
      }
      WordEvent.create(payload)
    end
  end
end
