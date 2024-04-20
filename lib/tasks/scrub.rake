require 'csv'
namespace :scrub do
  task gather_info: :environment do

    all_images = Image.all
    puts "all_images.count: #{all_images.count}"
    menu_images = Image.menu_images
    puts "menu_images.count: #{menu_images.count}"
    non_menu_images = Image.non_menu_images
    puts "non_menu_images.count: #{non_menu_images.count}"
    public_user_made_images = Image.public_img.non_menu_images
    puts "public_user_made_images.count: #{public_user_made_images.count}"
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
end
