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
end
