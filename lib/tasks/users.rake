namespace :users do
  desc "Create a new user with optional communicator account and board. Example: rake users:create_basic_user_with_optional_communicator[true]"
  task :create_basic_user_with_optional_communicator, [:create_communicator] => :environment do |t, args|
    user = create_seed_user(plan_type: "basic", communicator_limit: 1, board_limit: 25)
    if args[:create_communicator]
      puts "Creating communicator account for user"
      communicator_account = create_seed_communicator(user)
    else
      puts "No communicator account created"
    end
    puts "Done!"
  end

  desc "Create word events for an existing communicator account Example: rake users:create_word_events_for_communicator[1]"
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
      new_name = sample_board.name
      board_to_use = user.boards.find_by(name: new_name)
      if board_to_use.nil?
        board_to_use = sample_board.clone_with_images(user.id, new_name)
      end
    else
      board_to_use = communicator_account.child_boards.sample.board
    end
    words = board_to_use.current_word_list
    communicator_account.update!(last_sign_in_at: Time.current)

    create_word_events(words, user, board_to_use, communicator_account)
  end
end

def create_seed_user(plan_type: "basic", communicator_limit: 1, board_limit: 25)
  user = User.create!(email: Faker::Internet.email,
                      password: "111111", password_confirmation: "111111",
                      name: Faker::Name.name, plan_type: plan_type, settings: { "communicator_limit" => communicator_limit, "board_limit" => board_limit })
  puts "User created with email: #{user.email} and password: 111111"
  stripe_customer = Stripe::Customer.create({
    name: user.name,
    email: user.email,
  })
  stripe_customer_id = stripe_customer.id
  user.update!(stripe_customer_id: stripe_customer_id)
  user
end

def create_seed_communicator(user)
  comm_account_name = "#{user.name}'s Communicator Account"
  comm_account_username = Faker::Internet.username(specifier: 6..12, separators: %w(. _ -))
  communicator_account = user.child_accounts.create!(name: comm_account_name,
                                                     passcode: "111111",
                                                     username: comm_account_username)
  puts "Communicator account created with username: #{communicator_account.username} and password: 111111"
  communicator_account
end

def create_word_events(words, user, board, communicator_account)
  words.each do |word|
    puts "Creating word event for word: #{word}"
    random_days_ago = rand(0..7)
    payload = {
      word: word,
      previous_word: words.sample,
      timestamp: Faker::Time.backward(days: random_days_ago),
      user_id: user.id,
      board_id: board.id,
      team_id: user.current_team_id,
      child_account_id: communicator_account&.id,
    }
    WordEvent.create(payload)
  end
end
