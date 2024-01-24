# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end
# ProductCategory.delete_all
tokens = ProductCategory.find_or_create_by name: "tokens"
# ebikes = ProductCategory.create! name: "e-bikes"
# ProductCategory.create! name: "kids bikes & accessories"
# ProductCategory.create! name: "parts"
# ProductCategory.create! name: "bikes accessories"
# ProductCategory.create! name: "clothing & shoes"

# Product.delete_all
Product.find_or_create_by name: "5 tokens", price: 1, coin_value: 5, active: true, product_category: tokens
# Product.find_or_create_by name: "100 tokens", price: 10, coin_value: 100, active: true, product_category: tokens
# Product.find_or_create_by name: "200 tokens", price: 15, coin_value: 200, active: true, product_category: tokens
# Product.find_or_create_by name: "500 tokens", price: 20, coin_value: 500, active: true, product_category: tokens


parent_resource = PredefinedResource.find_or_create_by name: "Default", resource_type: "Board"
admin_user = User.admins.first
# Predefined communication boards :
# • Eat - common foods
# • Drink - common drinks
# • Feel - happy, sad, angry, confused
# • Play - common children toys and creativity items
# • Say Hello To - mom, dad, grandparents
new_images = []
feeling_board = Board.find_or_create_by!(name: "Feelings", description: "How are you feeling today?", predefined: true, parent: parent_resource, user: admin_user)
feeling_images = [
    { label: "Happy", image_prompt: "Create an image of happy" },
    { label: "Sad", image_prompt: "Create an image of sad" },
    { label: "Angry", image_prompt: "Create an image of angry" },
    { label: "Confused", image_prompt: "Create an image of confused" },
    { label: "Tired", image_prompt: "Create an image of tired" },
    { label: "Sick", image_prompt: "Create an image of sick" },
    { label: "Scared", image_prompt: "Create an image of scared" },
    { label: "Excited", image_prompt: "Create an image of excited" },
    { label: "Bored", image_prompt: "Create an image of bored" },
    { label: "Surprised", image_prompt: "Create an image of surprised" },
    { label: "Proud", image_prompt: "Create an image of proud" },
    { label: "Shy", image_prompt: "Create an image of shy" },
    { label: "Worried", image_prompt: "Create an image of worried" },
    { label: "Silly", image_prompt: "Create an image of silly" }
]

feeling_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    feeling_board.add_image(i.id)
end

puts "Created #{feeling_images.count} feeling images"

# Create an Eating Board
eating_board = Board.find_or_create_by!(name: "Eat", description: "What would you like to eat?", predefined: true, predefined: true, parent: parent_resource, user: admin_user)

# Images for Eating Board
eating_images = [
    { label: "Apple", image_prompt: "Create an image of an apple" },
    { label: "Sandwich", image_prompt: "Create an image of a sandwich" },
    { label: "Pizza", image_prompt: "Create an image of a pizza slice" },
    { label: "Pasta", image_prompt: "Create an image of pasta" },
    { label: "Carrots", image_prompt: "Create an image of carrots" },
    { label: "Chicken", image_prompt: "Create an image of chicken" },
    { label: "Fish", image_prompt: "Create an image of fish" },
    { label: "Rice", image_prompt: "Create an image of rice" },
    { label: "Cheese", image_prompt: "Create an image of cheese" },
    { label: "Bread", image_prompt: "Create an image of bread" }
]

eating_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    eating_board.add_image(i.id)
end
puts "Created #{eating_images.count} eating images"
drinking_board = Board.find_or_create_by!(name: "Drink", description: "What would you like to drink?", predefined: true, predefined: true, parent: parent_resource, user: admin_user)

drinking_images = [
    { label: "Water", image_prompt: "Create an image of a glass of water" },
    { label: "Milk", image_prompt: "Create an image of a glass of milk" },
    { label: "Juice", image_prompt: "Create an image of a glass of juice" },
    { label: "Soda", image_prompt: "Create an image of a can of soda" },
    { label: "Tea", image_prompt: "Create an image of a cup of tea" },
    { label: "Coffee", image_prompt: "Create an image of a cup of coffee" },
    { label: "Smoothie", image_prompt: "Create an image of a smoothie" },
    { label: "Hot Chocolate", image_prompt: "Create an image of hot chocolate" },
    { label: "Lemonade", image_prompt: "Create an image of lemonade" },
    { label: "Iced Tea", image_prompt: "Create an image of iced tea" }
]

drinking_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    drinking_board.add_image(i.id)
end
puts "Created #{drinking_images.count} drinking images"
play_board = Board.find_or_create_by!(name: "Play", description: "What would you like to play with?", predefined: true, predefined: true, parent: parent_resource, user: admin_user)

play_images = [
    { label: "Doll", image_prompt: "Create an image of a doll" },
    { label: "Car", image_prompt: "Create an image of a toy car" },
    { label: "Ball", image_prompt: "Create an image of a ball" },
    { label: "Puzzle", image_prompt: "Create an image of a puzzle" },
    { label: "Blocks", image_prompt: "Create an image of building blocks" },
    { label: "Teddy Bear", image_prompt: "Create an image of a teddy bear" },
    { label: "Book", image_prompt: "Create an image of a book" },
    { label: "Crayons", image_prompt: "Create an image of crayons" },
    { label: "Bike", image_prompt: "Create an image of a bike" },
    { label: "Scooter", image_prompt: "Create an image of a scooter" }
]

play_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    play_board.add_image(i.id)
end
puts "Created #{play_images.count} play images"
greetings_board = Board.find_or_create_by!(name: "Say Hello To", description: "Who would you like to say hello to?", predefined: true, predefined: true, parent: parent_resource, user: admin_user)

greetings_images = [
    { label: "Mom", image_prompt: "Create an image representing mom" },
    { label: "Dad", image_prompt: "Create an image representing dad" },
    { label: "Grandma", image_prompt: "Create an image representing grandma" },
    { label: "Grandpa", image_prompt: "Create an image representing grandpa" },
    { label: "Teacher", image_prompt: "Create an image representing a teacher" },
    { label: "Friend", image_prompt: "Create an image representing a friend" },
    { label: "Sibling", image_prompt: "Create an image representing a sibling" },
    { label: "Aunt", image_prompt: "Create an image representing an aunt" },
    { label: "Uncle", image_prompt: "Create an image representing an uncle" },
    { label: "Pet", image_prompt: "Create an image representing a pet" }
]

greetings_images.each do |image|
i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
new_images << i
greetings_board.add_image(i.id)
end

top_five_boards = [
  "Daily Routines",
  "School Activities",
  "Outdoor Activities",
  "Feelings and Emotions",
  "Places to Go"
]

daily_routine_board = Board.find_or_create_by!(name: "Daily Routines", description: "What is your daily routine?", predefined: true, parent: parent_resource, user: admin_user)

# Images for Daily Routines Board
daily_routine_images = [
    { label: "Brushing Teeth", image_prompt: "Create an image of brushing teeth" },
    { label: "Getting Dressed", image_prompt: "Create an image of getting dressed" },
    { label: "Breakfast", image_prompt: "Create an image of breakfast" },
    { label: "School Bus", image_prompt: "Create an image of a school bus" },
    { label: "Bedtime", image_prompt: "Create an image of bedtime" }
]

daily_routine_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    daily_routine_board.add_image(i.id)
end
puts "Created #{daily_routine_images.count} daily routine images"

school_activities_board = Board.find_or_create_by!(name: "School Activities", description: "What do you do at school?", predefined: true, parent: parent_resource, user: admin_user)
# Images for School Activities Board
school_activities_images = [
    { label: "Reading", image_prompt: "Create an image of reading a book" },
    { label: "Writing", image_prompt: "Create an image of writing" },
    { label: "Art Class", image_prompt: "Create an image of an art class" },
    { label: "Lunchtime", image_prompt: "Create an image of lunchtime at school" },
    { label: "Playing at Recess", image_prompt: "Create an image of playing at recess" }
]

school_activities_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    school_activities_board.add_image(i.id)
end
puts "Created #{school_activities_images.count} school activities images"

outdoor_activities_board = Board.find_or_create_by!(name: "Outdoor Activities", description: "What do you do outside?", predefined: true, parent: parent_resource, user: admin_user)
# Images for Outdoor Activities Board
outdoor_activities_images = [
    { label: "Playing in the Park", image_prompt: "Create an image of playing in the park" },
    { label: "Swimming", image_prompt: "Create an image of swimming" },
    { label: "Biking", image_prompt: "Create an image of biking" },
    { label: "Hiking", image_prompt: "Create an image of hiking" },
    { label: "Picnic", image_prompt: "Create an image of a picnic" }
    ]

outdoor_activities_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    outdoor_activities_board.add_image(i.id)
end
puts "Created #{outdoor_activities_images.count} outdoor activities images"

places_to_go_board = Board.find_or_create_by!(name: "Places to Go", description: "Where would you like to go?", predefined: true, parent: parent_resource, user: admin_user)
places_to_go_images = [
    { label: "Supermarket", image_prompt: "Create an image of a supermarket" },
    { label: "Doctor's Office", image_prompt: "Create an image of a doctor's office" },
    { label: "School", image_prompt: "Create an image of a school" },
    { label: "Park", image_prompt: "Create an image of a park" },
    { label: "Library", image_prompt: "Create an image of a library" }
]

places_to_go_images.each do |image|
    i = Image.public_images.find_or_create_by!(label: image[:label], image_prompt: image[:image_prompt])
    new_images << i
    places_to_go_board.add_image(i.id)
end
puts "Created #{places_to_go_images.count} places to go images"

# puts "Running generate image job for #{new_images.count} new images"
# Image.run_generate_image_job_for(new_images)
# puts "Finished running generate image job for #{new_images.count} new images"