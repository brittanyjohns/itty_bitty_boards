namespace :users do
  desc "Create a full demo user with communicators, boards, and word events spread over time. Example: rake users:create_demo[3,60,pro]"
  task :create_demo, [:num_communicators, :days_ago, :plan_type] => :environment do |t, args|
    num_communicators = (args[:num_communicators] || 2).to_i
    days_ago = (args[:days_ago] || 60).to_i
    plan_type = args[:plan_type] || "pro"

    puts "=== Creating demo user (plan: #{plan_type}) with #{num_communicators} communicator(s) over #{days_ago} days ==="

    user = create_seed_user(plan_type: plan_type, communicator_limit: num_communicators, board_limit: 50)

    num_communicators.times do |i|
      name = FFaker::Name.html_safe_name
      puts "\n--- Communicator #{i + 1}: #{name} ---"
      communicator_account = create_seed_communicator(user, name)
      communicator_account.update!(last_sign_in_at: Time.current - rand(0..7).days)

      boards = communicator_account.child_boards.includes(:board).to_a
      3.times { create_board_for_communicator(communicator_account) } if boards.size < 3
      communicator_account.reload

      adj_min = (days_ago / 2.0).ceil
      adj_max = days_ago
      communicator_account.child_boards.includes(:board).each_with_index do |child_board, idx|
        board = child_board.board
        words = board.current_word_list
        next if words.blank?

        adj_days = rand(adj_min..adj_max)
        timestamp = Time.current - adj_days.days + idx.seconds
        count = create_word_events(words, user, board, communicator_account, timestamp: timestamp)
        puts "  Created #{count} events for board '#{board.name}' (~#{adj_days} days ago)"
      end
    end

    puts "\n=== Done! ==="
    puts "Email: #{user.email}"
    puts "Password: 111111"
    puts "Plan: #{user.plan_type}"
    puts "Communicators: #{user.communicator_accounts.count}"
  end


  desc "Seed word events for a single existing communicator account. Example: rake users:seed_word_events_for_communicator[99,60]"
  task :seed_word_events_for_communicator, [:account_id, :days_ago] => :environment do |t, args|
    communicator_account = ChildAccount.includes(:user, child_boards: :board).find(args[:account_id])
    days_ago = (args[:days_ago] || 60).to_i
    user = communicator_account.user

    if communicator_account.child_boards.empty?
      puts "No boards found for communicator #{communicator_account.id} — run create_word_events_for_communicator with create_board=true first"
      next
    end

    puts "=== Seeding word events for #{communicator_account.name} (ID: #{communicator_account.id}) over #{days_ago} days ==="

    adj_min = (days_ago / 2.0).ceil
    adj_max = days_ago

    communicator_account.child_boards.each_with_index do |child_board, idx|
      board = child_board.board
      words = board.current_word_list
      next if words.blank?

      adj_days = rand(adj_min..adj_max)
      timestamp = Time.current - adj_days.days + idx.seconds
      create_word_events(words, user, board, communicator_account, timestamp: timestamp)
      puts "  Created #{words.size * 2} events for '#{board.name}' (~#{adj_days} days ago)"
    end

    puts "\n=== Done! ==="
  end

  desc "Seed word events for all communicators on an existing user. Example: rake users:seed_word_events_for_user[42,60]"
  task :seed_word_events_for_user, [:user_id, :days_ago] => :environment do |t, args|
    user = User.includes(communicator_accounts: { child_boards: :board }).find(args[:user_id])
    days_ago = (args[:days_ago] || 60).to_i

    if user.communicator_accounts.empty?
      puts "No communicator accounts found for user #{user.id}"
      next
    end

    puts "=== Seeding word events for user #{user.id} (#{user.email}) over #{days_ago} days ==="

    adj_min = (days_ago / 2.0).ceil
    adj_max = days_ago

    user.communicator_accounts.each do |communicator_account|
      puts "\n--- #{communicator_account.name} (ID: #{communicator_account.id}) ---"

      if communicator_account.child_boards.empty?
        puts "  No boards — skipping"
        next
      end

      communicator_account.child_boards.each_with_index do |child_board, idx|
        board = child_board.board
        words = board.current_word_list
        next if words.blank?

        adj_days = rand(adj_min..adj_max)
        timestamp = Time.current - adj_days.days + idx.seconds
        create_word_events(words, user, board, communicator_account, timestamp: timestamp)
        puts "  Created #{words.size * 2} events for '#{board.name}' (~#{adj_days} days ago)"
      end
    end

    puts "\n=== Done! ==="
  end

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

      create_word_events(words, user, board_to_use, communicator_account, timestamp: Time.current - rand(1..30).days)
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

    comm_boards = communicator_account.child_boards.includes(:board).sample(10)

    adj_days_ago_min = (days_ago / 2.size.to_f).ceil # Adjust the days_ago to spread events over the specified range
    adj_days_ago_max = days_ago
    count = 0
    comm_boards.each_with_index do |child_board, index|
      board_to_use = child_board.board
      words = board_to_use.current_word_list
      adj_days_ago = rand(adj_days_ago_min..adj_days_ago_max)

      timestamp = Time.current - adj_days_ago.days
      timestamp += index.seconds
      count += create_word_events(words, user, board_to_use, communicator_account, timestamp: timestamp)
    end

    puts "Done! - Created word events for account ID #{communicator_account.id}. - Days ago: #{days_ago}, Events processed: #{count}"
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

TYPICAL_HOURS = [7, 9, 11, 13, 15, 17, 19].freeze

def create_word_events(words, user, board, communicator_account, timestamp:, sessions: 6)
  return if words.blank?

  base_day = timestamp.beginning_of_day
  total = 0

  sessions.times do |s|
    # Each session is on a different day offset from the base timestamp
    day_offset = s * (30 / sessions.to_f).floor
    session_day = base_day + day_offset.days
    hour = TYPICAL_HOURS.sample
    session_start = session_day.change(hour: hour, min: rand(0..30))

    # Click through a random subset of words (at least half, usually all)
    session_words = words.sample(rand((words.size / 2)..words.size))
    prev_word = nil

    session_words.each_with_index do |word, i|
      # Clicks are a few seconds apart, like a real board session
      click_time = session_start + (i * rand(3..10)).seconds
      WordEvent.create(
        word: word,
        previous_word: prev_word,
        timestamp: click_time,
        user_id: user.id,
        board_id: board.id,
        child_account_id: communicator_account&.id,
      )
      prev_word = word
      total += 1
    end
  end

  total
end
