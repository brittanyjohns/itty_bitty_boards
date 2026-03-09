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

  desc "Find a user by id and add x number of communicator accounts. Example: rake users:add_communicator_accounts[1,5]"
  task :add_communicator_accounts, [:user_id, :num_accounts] => :environment do |t, args|
    user = User.find(args[:user_id])
    name = user.name
    if user.nil?
      puts "User not found"
      return
    end
    if user.name.blank?
      user.update!(name: FFaker::Name.name)
    end
    num_accounts = args[:num_accounts].to_i
    acct_ids = []
    num_accounts.times do
      account_name = FFaker::Name.html_safe_name
      puts "Account name: #{account_name}"
      communicator_account = create_seed_communicator(user, account_name)
      board_to_use = communicator_account.child_boards.sample.board
      words = board_to_use.current_word_list
      communicator_account.update!(last_sign_in_at: Time.current)

      create_word_events(words, user, board_to_use, communicator_account)
      acct_ids << communicator_account.id
      puts "Created communicator account with username: #{communicator_account.username} and ID #{communicator_account.id}"
    end
    puts "Done! : #{acct_ids}"
  end

  desc "Create word events for an existing communicator account Example: rake users:create_word_events_for_communicator[1,true]"
  task :create_word_events_for_communicator, [:account_id, :create_board, :days_ago] => :environment do |t, args|
    communicator_account = ChildAccount.includes(:user, :child_boards).find(args[:account_id])
    user = communicator_account.user
    if communicator_account.nil?
      puts "Account not found"
      return
    end
    board_to_use = nil
    if communicator_account.child_boards.empty? || args[:create_board]
      puts "No boards found for account"
      create_board_for_communicator(communicator_account)
      communicator_account.reload
    end

    communicator_account.update!(last_sign_in_at: Time.current)

    days_ago = args[:days_ago].to_i || 30

    # board_to_use = communicator_account.child_boards.sample.board
    limit = 8
    communicator_account.child_boards.each do |child_board|
      count = 0

      board_to_use = child_board.board
      words = board_to_use.current_word_list
      puts "Creating word events for account ID #{communicator_account.id} with words: #{words.join(", ")} and days_ago: #{days_ago}"

      create_word_events(words, user, board_to_use, communicator_account, days_ago)
      count += 1
      break if count >= limit
    end
    profile = communicator_account.profile
    update_profile(profile) if profile.intro.blank? || profile.bio.blank?
    puts "Done!"
  end

  desc "Create recent words events for for an existing communicator account Example: rake users:create_recent_word_events_for_communicator[1]"
  task :create_recent_word_events_for_communicator, [:account_id] => :environment do |t, args|
    communicator_account = ChildAccount.includes(:user, :child_boards).find(args[:account_id])
    user = communicator_account.user
    if communicator_account.nil?
      puts "Account not found"
      return
    end
    board_to_use = nil
    if communicator_account.child_boards.empty?
      puts "No boards found for account"
      create_board_for_communicator(communicator_account)
      communicator_account.reload
    end

    board_to_use = communicator_account.child_boards.sample.board
    words = board_to_use.current_word_list
    communicator_account.update!(last_sign_in_at: Time.current)

    puts "Creating recent word events for account ID #{communicator_account.id} with words: #{words.join(", ")}"

    create_word_events(words, user, board_to_use, communicator_account, timestamp: Time.current - 1.day)
    profile = communicator_account.profile
    update_profile(profile) if profile.intro.blank? || profile.bio.blank?
    puts "Done!"
  end
end

def create_board_for_communicator(communicator_account)
  user = communicator_account.user
  sample_board = Board.predefined.sample
  new_name = sample_board.name
  board_to_use = user.boards.find_by(name: new_name)
  if board_to_use.nil?
    board_to_use = sample_board.clone_with_images(user.id, new_name)
  end
  communication_board = communicator_account.child_boards.create!(board: board_to_use)
  if communicator_account
    puts "Comm: #{communicator_account}"
  else
    puts "Nothing"
  end
  puts "Created board for communicator account: #{communication_board.board.name}"
  communication_board
end

def create_seed_user(plan_type: "basic", communicator_limit: 1, board_limit: 25)
  user = User.create!(email: FFaker::Internet.safe_email,
                      password: "111111", password_confirmation: "111111",
                      name: FFaker::Name.name, plan_type: plan_type, settings: { "paid_communicator_limit" => communicator_limit, "board_limit" => board_limit })
  puts "User created with email: #{user.email} and password: 111111"
  stripe_customer = Stripe::Customer.create({
    name: user.name,
    email: user.email,
  })
  stripe_customer_id = stripe_customer.id
  user.update!(stripe_customer_id: stripe_customer_id)
  user
end

def create_seed_communicator(user, name = nil)
  puts "Name is a #{name.class} - #{name}"
  short_name = name.split(" ").first if name
  puts "short_name: #{short_name}"
  comm_account_name = name || "#{user.name}'s Communicator Account"
  comm_account_username = FFaker::Internet.user_name
  communicator_account = user.communicator_accounts.create!(name: comm_account_name,
                                                            passcode: "111111",
                                                            username: comm_account_username)
  puts "Communicator account created with username: #{communicator_account.username} and password: 111111"
  communicator_account.reload
  create_board_for_communicator(communicator_account)
  profile = communicator_account.profile
  update_profile(profile)
  communicator_account.reload

  communicator_account
end

def update_profile(profile)
  unless profile.avatar.attached?
    profile.set_fake_avatar
  end
  profile.save!
end

def create_word_events(words, user, board, communicator_account, days_ago = 30)
  random_days_ago = rand(0..days_ago)
  timestamp = FFaker::Time.between(Date.today - random_days_ago, Date.today)
  puts "Creating word events for user ID #{user.id} on board ID #{board.id} with timestamp: #{timestamp}"
  words.each_with_index do |word, index|
    ts_for_event = timestamp + index.minutes
    puts "Creating WordEvent for word: #{word}, previous_word: #{words[index - 1]}, timestamp: #{ts_for_event}, user_id: #{user.id}, board_id: #{board.id}, child_account_id: #{communicator_account&.id}"
    payload = {
      word: word,
      previous_word: words[index - 1],
      timestamp: ts_for_event,
      user_id: user.id,
      board_id: board.id,
      child_account_id: communicator_account&.id,
    }
    WordEvent.create(payload)
  end
end
