namespace :db do
  desc "Seed users into the database. Run `rake db:seed_users`"
  task seed_users: :environment do
    puts "Starting to seed users..."
    User.create!(email: "bhannajohns@gmail.com", password: "000000", password_confirmation: "000000", role: "admin", tokens: 100)
  end

  desc "Seed scenarios into the database. Run `rake db:seed_scenarios`"
  task seed_scenarios: :environment do
    puts "Starting to seed scenarios..."

    # Ensure the seed user exists
    seed_user = User.find_by(email: "test@test.com")
    unless seed_user
      puts "Seed user not found. Please ensure a user with email 'test@test.com' exists."
      seed_user = User.create!(email: "test@test.com", password: "000000", password_confirmation: "000000", role: "user")
    end

    # Path to your JSON file with scenarios data db/seed_data
    scenarios_file = Rails.root.join("db", "seed_data", "scenarios", "data.json")
    unless File.exist?(scenarios_file)
      puts "Scenarios file not found at #{scenarios_file}. Exiting..."
      exit
    end

    scenarios_data = File.read(scenarios_file)
    scenarios = JSON.parse(scenarios_data)

    scenarios.each do |scenario_hash|
      # Build attributes hash suitable for OpenaiPrompt creation
      scenario_attributes = scenario_hash.symbolize_keys.slice(
        :prompt_text, :revised_prompt, :send_now, :deleted_at, :sent_at, :private,
        :age_range, :token_limit, :response_type, :description, :number_of_images
      ).merge(user_id: seed_user.id)

      prompt_text = scenario_attributes[:prompt_text] + " " + scenario_attributes[:description]
      puts "Prompt text: #{prompt_text}"

      # Create scenario unless one with the same prompt_text already exists for the user
      existing_scenario = OpenaiPrompt.exists?(user_id: seed_user.id, prompt_text: prompt_text)
      unless existing_scenario
        new_scenario = OpenaiPrompt.create!(scenario_attributes)
        puts "Scenario #{new_scenario.inspect} created."
      else
        puts "Scenario with prompt_text '#{scenario_attributes[:prompt_text]}' already exists. Skipping..."
      end
    end

    puts "Scenarios seeding completed."
  end
end
