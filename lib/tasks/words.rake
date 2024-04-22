namespace :db do
  desc "Seed words into the database. Run `rake db:seed_words`"
  task seed_words: :environment do
    puts "Starting to seed words..."

    # Path to your JSON file with words data db/seed_data
    words_file = Rails.root.join("db", "seed_data", "words", "data.json")
    unless File.exist?(words_file)
      puts "words file not found at #{words_file}. Exiting..."
      exit
    end

    words_data = File.read(words_file)
    words = JSON.parse(words_data)

    words.each do |word_hash|
      # Build attributes hash suitable for OpenaiPrompt creation
      label = word_hash["label"]
      next_words = word_hash["next_words"]
      puts "Label: #{label}"
      puts "Next Words: #{next_words}"
      existing_word = Image.find_by(label: label)
      if existing_word
        existing_word.update(next_words: next_words)
      else
        existing_word = Image.create(label: label, next_words: next_words)
      end
    end

    puts "words seeding completed."
  end

  desc "Seed next words into the database. Run `rake db:seed_next_words`"
  task seed_next_words: :environment do
    puts "Starting to seed next words..."

    # Update images in batches of 5
    Image.find_in_batches(batch_size: 50) do |images|
      images.each do |image|
        next_words = image.next_words
        next unless next_words.blank?

        puts "Getting next words for #{image.label}..."
        image.set_next_words!
      end
    end
  end

  desc "Seed base board with images for an AAC device. Run `rake db:seed_base_board`"
  task seed_base_board: :environment do
    # Seed script for creating boards with images for an AAC device
    parent_resource = PredefinedResource.find_or_create_by name: "Default", resource_type: "Board"
    admin_user = User.admin.first # Ensure you have an admin or a specific user to associate with the created boards

    boards_info = [
      {
        name: "Base",
        description: "Base board for the AAC device.",
        image_labels: [
          'I',
          'you',
          'he',
          'she',
          'it',
          'we',
          'they',
          'that',
          'this',
          'the',
          'a',
          'is',
          'can',
          'will',
          'do',
          "don't",
          'go',
          'want',
          'like',
          'see',
          'come',
          'eat',
          'drink',
          'play',
          'stop',
          'help',
          'please',
          'thank you',
          'yes',
          'no',
          'and',
          'or',
          'but',
          'because',
          'if',
          'to',
          'from',
          'with',
          'at',
          'in',
          'on',
          'out',
          'up',
          'down',
          'more',
          'less',
          'big',
          'small',
          'good',
          'bad',
          'happy',
          'sad',
      ]
      }]

    boards_info.each do |board_info|
      board = Board.find_or_create_by!(name: board_info[:name], description: board_info[:description], user: admin_user, predefined: true, parent: parent_resource)

      board_info[:image_labels].each do |label|
        # Here, adjust image creation to fit your model's requirements.
        # This might include setting a default or placeholder image path if your model requires it.
        new_image = Image.public_img.find_or_create_by!(label: label) do |image|
          # Assuming you have an attribute 'image_prompt' or similar for the description or actual image content
          image.image_prompt = "Create an image representing '#{label}'."
          # Add additional attributes here as necessary, such as setting a default image file, etc.
        end
        board.add_image(new_image.id)
      end
    end

    puts "Seeding completed."
  end
end
