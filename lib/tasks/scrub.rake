require 'csv'
namespace :scrub do
  task gather_info: :environment do

    all_images = Image.all
    puts "all_images.count: #{all_images.count}"
    menu_images = Image.menu_images
    puts "menu_images.count: #{menu_images.count}"
    non_menu_images = Image.non_menu_images
    puts "non_menu_images.count: #{non_menu_images.count}"
    non_scenarios = Image.non_scenarios
    puts "non_scenarios.count: #{non_scenarios.count}"
    no_image_type = Image.no_image_type
    puts "no_image_type.count: #{no_image_type.count}"
    public_img = Image.public_img
    puts "public_img.count: #{public_img.count}"
  end

  task create_next_words: :environment do
    public_user_made_images = Image.public_img.non_menu_images
    public_user_made_images.each do |image|
      begin
        image.create_words_from_next_words
        puts "\n\nNo errors in the CreateNewWordsJob\n\n"
      rescue => e
        puts "\n**** SIDEKIQ - CreateNewWordsJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end

  task export_images_to_csv: :environment do
    images = Image.all
    CSV.open("images.csv", "wb") do |csv|
      csv << Image.column_names
      images.each do |image|
        csv << image.attributes.values
      end
    end
  end

  task categorize_images: :environment do
    remaining_images = Image.non_menu_images.where(part_of_speech: nil)
    puts "remaining_images.count: #{remaining_images.count}"
    images = Image.non_menu_images.where(part_of_speech: nil).limit(100)
    puts "images.count: #{images.count}"
    images.each do |image|
      begin
        image.categorize!
        puts "\n\nNo errors in the CategorizeImageJob\n\n"
      rescue => e
        puts "\n**** SIDEKIQ - CategorizeImageJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end


end
