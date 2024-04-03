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

  desc "Seed images into the database. Run `rake db:seed_images`"
  task seed_images: :environment do
    # Seed script for creating boards with images for an AAC device
    parent_resource = PredefinedResource.find_or_create_by name: "Default", resource_type: "Board"
    admin_user = User.admins.first # Ensure you have an admin or a specific user to associate with the created boards

    boards_info = [
      { name: "Greetings", description: "Common greetings and salutations.", image_labels: ["Hello", "Goodbye", "Good morning", "Good night", "How are you?", "I’m fine", "Thank you", "Please", "Yes", "No", "Excuse me", "Sorry", "You’re welcome", "See you later", "Nice to meet you", "Thank you", "Welcome", "Cheers", "Good evening", "Good afternoon"] },
      { name: "Basic Needs", description: "Expressing basic needs and wants.", image_labels: ["Water", "Food", "Bathroom", "Help", "Rest", "Sleep", "Hungry", "Thirsty", "Sick", "Pain", "Medicine", "Hot", "Cold", "More", "Less", "Yes", "No", "Please", "Thank you", "Clothes", "Shower", "Doctor", "Quiet", "Noise"] },
      { name: "Emotions", description: "Identifying and expressing feelings.", image_labels: ["Happy", "Sad", "Angry", "Tired", "Scared", "Excited", "Worried", "Surprised", "Silly", "Bored", "Calm", "Nervous", "Embarrassed", "Proud", "Confused", "Frustrated", "Grateful", "Lonely", "Overwhelmed", "Content"] },
      { name: "Daily Activities", description: "Common daily activities and hobbies.", image_labels: ["School", "Work", "Home", "Park", "Shopping", "Eating", "Cooking", "Cleaning", "Reading", "Drawing", "Playing", "Watching TV", "Exercise", "Swimming", "Running", "Biking", "Homework", "Music", "Dancing", "Singing", "Bathing", "Sleeping", "Waking up", "Dressing"] },
      { name: "Questions", description: "Asking questions to learn about the world.", image_labels: ["Who?", "What?", "Where?", "When?", "Why?", "How?", "Which?", "Whose?", "Can I?", "May I?", "Should I?", "Would you?", "Could you?", "Will you?", "What time?", "How much?", "How many?", "Do you like?", "What’s that?", "Are you ok?", "Do you want?", "Can you?", "Have you?", "Did you?"] },
      { name: "Safety and Emergencies", description: "Key phrases and words for safety and emergencies.", image_labels: ["Help", "Emergency", "Safe", "Danger", "Stop", "Go", "Call 911", "Fire", "Police", "Ambulance", "Hurt", "Lost", "Found", "Stay", "Leave", "Evacuate", "Alarm", "Lock", "Unlock", "Flashlight", "Battery", "First aid", "Medic", "Caution"] },
      { name: "Personal Identification", description: "Words related to personal identity and information.", image_labels: ["Name", "Age", "Address", "Phone number", "School", "Birthday", "Family", "Friend", "Teacher", "Student", "Parent", "Sibling", "Pet", "Doctor", "Nurse", "Allergy", "Medication", "Condition", "Emergency contact", "ID number", "Passport", "License", "Social security", "Insurance"] },
      { name: "Time and Scheduling", description: "Words and phrases for discussing time and schedules.", image_labels: ["Day", "Night", "Morning", "Afternoon", "Evening", "Today", "Tomorrow", "Yesterday", "Week", "Weekend", "Month", "Year", "Schedule", "Appointment", "Holiday", "Birthday", "Anniversary", "Deadline", "Alarm", "Timer", "Start", "End", "Late", "Early"] },
      { name: "Food and Drink", description: "Common foods and beverages.", image_labels: ["Water", "Juice", "Milk", "Coffee", "Tea", "Bread", "Cheese", "Fruit", "Vegetable", "Meat", "Fish", "Chicken", "Rice", "Pasta", "Pizza", "Burger", "Salad", "Soup", "Snack", "Dessert", "Breakfast", "Lunch", "Dinner", "Supper"] },
      { name: "School Life", description: "Words related to school and education.", image_labels: ["Teacher", "Student", "Class", "Lesson", "Homework", "Test", "Exam", "Study", "Read", "Write", "Draw", "Paint", "Calculate", "Science", "History", "Geography", "Math", "Art", "Music", "Gym", "Break", "Lunch", "Library", "Playground"] },
      { name: "Outdoor Activities", description: "Activities and places to visit outdoors.", image_labels: ["Park", "Beach", "Camping", "Hiking", "Picnic", "Fishing", "Swimming", "Biking", "Running", "Walking", "Playground", "Garden", "Zoo", "Farm", "Market", "Festival", "Concert", "Sports game", "Barbecue", "Nature trail", "Lake", "Mountain", "River", "Forest"] },
      { name: "Feelings and Emotions II", description: "Further exploration of feelings and emotional states.", image_labels: ["Joyful", "Grateful", "Excited", "Surprised", "Hopeful", "Content", "Satisfied", "Proud", "Anxious", "Overwhelmed", "Jealous", "Disappointed", "Regretful", "Guilty", "Ashamed", "Lonely", "Nostalgic", "Curious", "Optimistic", "Pessimistic", "Sympathetic", "Empathetic", "Indifferent", "Bewildered"] },
      { name: "Communicating Needs", description: "Expressing and asking for what you need.", image_labels: ["Assistance", "Space", "Time", "Patience", "Understanding", "Privacy", "Respect", "Support", "Comfort", "Advice", "Guidance", "Permission", "Opportunity", "Break", "Quiet", "Company", "Explanation", "Apology", "Feedback", "Clarification", "Instruction", "Direction", "Reassurance", "Confirmation"] },
      { name: "Health and Wellness", description: "Terms related to health, wellness, and medical needs.", image_labels: ["Doctor", "Nurse", "Hospital", "Clinic", "Health", "Wellness", "Illness", "Injury", "Pain", "Medicine", "Treatment", "Recovery", "Surgery", "Appointment", "Vaccine", "Exercise", "Nutrition", "Diet", "Hygiene", "Rest", "Relaxation", "Stress", "Mental health", "Physical health"] },
      { name: "Household Items", description: "Common items found around the house.", image_labels: ["Furniture", "Appliance", "Utensil", "Device", "Gadget", "Tool", "Clothing", "Footwear", "Book", "Toy", "Game", "Decoration", "Plant", "Pet", "Cleaning supply", "Grocery", "Personal care product", "Electronics", "Bedding", "Kitchenware", "Bathroom accessory", "Office supply", "Outdoor equipment", "Vehicle"] },
      { name: "Transportation and Travel", description: "Modes of transport and travel-related terms.", image_labels: ["Car", "Bus", "Train", "Plane", "Bicycle", "Motorcycle", "Boat", "Ship", "Subway", "Taxi", "Ride-share", "Scooter", "Walking", "Ticket", "Passport", "Luggage", "Map", "Tour", "Reservation", "Destination", "Accommodation", "Sightseeing", "Airport", "Station"] },
      { name: "Shopping and Services", description: "Words related to shopping and various services.", image_labels: ["Store", "Market", "Mall", "Online shopping", "Cart", "Basket", "Checkout", "Sale", "Discount", "Cashier", "Customer service", "Delivery", "Return", "Exchange", "Warranty", "Product", "Brand", "Price", "Receipt", "Invoice", "Service", "Appointment", "Consultation", "Reservation"] },
      { name: "Community and Places", description: "Important places and spaces in the community.", image_labels: ["School", "Library", "Church", "Mosque", "Temple", "Hospital", "Clinic", "Police station", "Fire station", "Post office", "Bank", "Park", "Museum", "Theater", "Cinema", "Cafe", "Restaurant", "Gym", "Stadium", "Arena", "Gallery", "Zoo", "Aquarium", "Playground"] },
      { name: "Jobs and Occupations", description: "Various professions and job-related vocabulary.", image_labels: ["Teacher", "Doctor", "Nurse", "Engineer", "Artist", "Musician", "Actor", "Writer", "Chef", "Waiter", "Barista", "Carpenter", "Mechanic", "Pilot", "Driver", "Farmer", "Scientist", "Lawyer", "Police officer", "Firefighter", "Soldier", "Veterinarian", "Dentist", "Pharmacist"] },
      { name: "Technology and Media", description: "Terms associated with technology and media.", image_labels: ["Computer", "Tablet", "Smartphone", "App", "Website", "Social media", "Email", "Video", "Music", "Podcast", "Game", "Blog", "News", "Television", "Radio", "Camera", "Printer", "Headphones", "Speaker", "Microphone", "Remote", "Charger", "Battery", "Cable"] },
      {
        name: "Feelings",
        description: "Identify and express a wide range of feelings and emotions.",
        image_labels: [
          "Happy", "Sad", "Angry", "Excited", "Scared", "Worried", "Tired", "Surprised",
          "Confused", "Proud", "Embarrassed", "Disappointed", "Jealous", "Calm",
          "Frustrated", "Grateful", "Lonely", "Bored", "Relaxed", "Anxious",
          "Optimistic", "Pessimistic", "Hopeful", "Overwhelmed",
        ],
      },
      {
        name: "Daily Routines",
        description: "Words and phrases to discuss daily routines and activities.",
        image_labels: [
          "Morning routine", "Bedtime", "Mealtime", "School", "Work", "Exercise",
          "Homework", "Bath time", "Playtime", "Reading", "Shopping", "Cleaning",
          "Cooking", "Laundry", "Appointment", "Transportation", "Relaxing",
          "Visiting", "Eating out", "Watching TV", "Online browsing", "Gardening",
          "Walking dog", "Family time",
        ],
      },
      {
        name: "Social Interactions",
        description: "Facilitate social interactions with common phrases and questions.",
        image_labels: [
          "How are you?", "My name is", "I like", "I don’t like", "Can I join?",
          "What’s your name?", "How old are you?", "What do you like?", "Where are you from?",
          "Can you help me?", "Would you like to?", "Can we be friends?", "Do you want to play?",
          "What’s wrong?", "Can I help?", "Thank you", "Please", "Excuse me", "I’m sorry",
          "Good job", "Congratulations", "Let’s share", "Take turns", "How was your day?",
        ],
      },
      {
        name: "Classroom Essentials",
        description: "Key words and phrases for classroom communication and learning.",
        image_labels: [
          "Question", "Answer", "Repeat", "Explain", "Homework", "Test", "Quiz", "Project",
          "Study", "Read", "Write", "Draw", "Solve", "Understand", "Confused",
          "Listen", "Speak", "Teacher", "Student", "Classmate", "Break", "Lunch",
          "Library", "Field trip", "Assembly",
        ],
      },
      {
        name: "Health and Body",
        description: "Terms related to health, body parts, and medical needs.",
        image_labels: [
          "Doctor", "Nurse", "Medicine", "Pain", "Injury", "Sick", "Healthy", "Exercise",
          "Eat healthy", "Sleep", "Headache", "Stomachache", "Toothache", "Cold",
          "Flu", "Allergy", "Cough", "Fever", "Appointment", "Vaccine", "Hospital",
          "Clinic", "Emergency", "Body parts",
        ],
      },
    ]

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
