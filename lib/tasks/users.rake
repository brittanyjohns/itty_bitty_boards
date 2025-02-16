namespace :users do
  desc "Create a new user"
  task create_basic_user: :environment do
    user = User.create!(email: Faker::Internet.email,
                        password: "111111", password_confirmation: "111111",
                        name: Faker::Name.name, plan_type: "basic", settings: { "communicator_limit" => 1 })
    puts "User created with email: #{user.email} and password: 111111"

    communicator_account = user.child_accounts.create!(name: Faker::Name.name,
                                                       passcode: "111111",
                                                       username: Faker::Internet.user_name)
    puts "Communicator account created with username: #{communicator_account.username} and password: 111111"
    board_to_use = Board.predefined.sample
    new_name = "#{user.name}'s #{board_to_use.name} Board"
    new_board = board_to_use.clone_with_images(user.id, new_name)
    communicator_account.child_boards.create!(board: new_board)
    puts "Done! User and communicator account created with a board"
    words = new_board.board_images.map(&:label).uniq
    puts "Creating word events for user: word count: #{words.count}"
    words.each do |word|
      puts "Creating word event for word: #{word}"
      payload = {
        word: word,
        previous_word: words.sample,
        timestamp: Faker::Time.between(from: DateTime.now - 1, to: DateTime.now),
        user_id: user.id,
        board_id: new_board.id,
        team_id: user.current_team_id,
        child_account_id: communicator_account.id,
      }
      WordEvent.create(payload)
    end
  end
end
