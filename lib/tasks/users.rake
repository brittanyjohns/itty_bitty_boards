namespace :users do
  desc "Create a new user"
  task create_basic_user_with_comm: :environment do
    user = User.create!(email: Faker::Internet.email,
                        password: "111111", password_confirmation: "111111",
                        name: Faker::Name.name, plan_type: "basic", settings: { "communicator_limit" => 1 })
    puts "User created with email: #{user.email} and password: 111111"
    stripe_customer = Stripe::Customer.create({
      name: user.name,
      email: user.email,
    })
    comm_account_name = "#{user.name}'s Communicator Account"
    comm_account_username = Faker::Internet.username(specifier: comm_account_name, separators: %w(. _ -))
    communicator_account = user.child_accounts.create!(name: comm_account_name,
                                                       passcode: "111111",
                                                       username: comm_account_username)
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
  task :create_word_events_for_communicator, [:account_id, :create_board] => :environment do |t, args|
    communicator_account = ChildAccount.includes(:user, :child_boards).find(args[:account_id])
    user = communicator_account.user
    if communicator_account.nil?
      puts "Account not found"
      return
    end
    board_to_use = nil
    if communicator_account.child_boards.empty? || args[:create_board]
      puts "No boards found for account"
      sample_board = Board.predefined.sample
      new_name = "Copy of #{sample_board.name}"
      board_to_use = user.boards.find_by(name: new_name)
      if board_to_use.nil?
        board_to_use = sample_board.clone_with_images(user.id, new_name)
      end
      communicator_account.child_boards.create!(board: board_to_use)
      puts "Done! User and communicator account created with a board"
      words = board_to_use.board_images.map(&:label).uniq
    else
      board_to_use = communicator_account.child_boards.sample.board
      words = board_to_use.board_images.map(&:label).uniq if board_to_use
      puts "Creating word events for user: word count: #{words.count}"
    end
    puts "Communicator account created with username: #{communicator_account.username} and password: 111111"

    puts "Creating word events for user: word count: #{words.count}"
    words.each do |word|
      puts "Creating word event for word: #{word}"
      random_days_ago = rand(60..180)
      payload = {
        word: word,
        previous_word: words.sample,
        timestamp: Faker::Time.backward(days: random_days_ago),
        user_id: user.id,
        board_id: board_to_use.id,
        team_id: user.current_team_id,
        child_account_id: communicator_account.id,
      }
      WordEvent.create(payload)
    end
  end
  task create_basic_user: :environment do
    user = User.create!(email: Faker::Internet.email,
                        password: "111111", password_confirmation: "111111",
                        name: Faker::Name.name, plan_type: "basic", settings: { "communicator_limit" => 1, "board_limit" => 25 })
    puts "User created with email: #{user.email} and password: 111111"
    stripe_customer = Stripe::Customer.create({
      name: user.name,
      email: user.email,
    })
    puts "Done! User basic created - no communicator account"
    stripe_customer_id = stripe_customer.id
    puts "Stripe customer ID: #{stripe_customer_id}"
  end
  task create_free_user: :environment do
    user = User.create!(email: Faker::Internet.email,
                        password: "111111", password_confirmation: "111111",
                        name: Faker::Name.name, plan_type: "free", settings: { "communicator_limit" => 0, "board_limit" => 5 })
    puts "User created with email: #{user.email} and password: 111111"
    stripe_customer = Stripe::Customer.create({
      name: user.name,
      email: user.email,
    })
    puts "Done! User free created - no communicator account"
    stripe_customer_id = stripe_customer.id
    puts "Stripe customer ID: #{stripe_customer_id}"
  end
  task create_pro_user: :environment do
    user = User.create!(email: Faker::Internet.email,
                        password: "111111", password_confirmation: "111111",
                        name: Faker::Name.name, plan_type: "pro", settings: { "communicator_limit" => 5, "board_limit" => 125 })
    puts "User created with email: #{user.email} and password: 111111"
    stripe_customer = Stripe::Customer.create({
      name: user.name,
      email: user.email,
    })
    puts "Done! User pro created - no communicator account"
    stripe_customer_id = stripe_customer.id
    puts "Stripe customer ID: #{stripe_customer_id}"
  end
end
