module SeedHelper

    def predefined_resource(name = 'Default', resource_type = 'Board')
        PredefinedResource.find_or_create_by!(name: name, resource_type: resource_type)
    end

    def admin_user
        @admin_user ||= User.admins.first
    end

    def seed_boards_from_file(predefined_name = 'Default', file_number = 1)
        filename_prefix = predefined_name.downcase.gsub(' ', '_')
        filename = "#{filename_prefix}#{file_number}.json"
        puts "Seeding boards from file: #{filename}"
        board_data = json_data(filename_prefix, filename)
        new_images = []
        predefined_board_resource = predefined_resource(predefined_name)
        board_data.each do |category, words|
            puts "Creating board for #{category} - predefined_board_resource: #{predefined_board_resource.id} - admin_user: #{admin_user.id}"
            board = Board.find_or_create_by!(name: category, parent: predefined_board_resource, user_id: admin_user.id)
            words.each do |word|
                puts "Creating image for #{word}"
                image = Image.public_img.find_or_create_by!(label: word.downcase)
                new_images << image
                board.add_image(image.id)
            end
        end
        @new_images = new_images
    end

    def json_data(prefix, filename)
        File.open(Rails.root.join('db', 'seed_data', "#{prefix}", filename)) do |file|
            JSON.load(file)
        end
    end

    def run_all
        seed_boards_from_file('Default', 1)
        seed_boards_from_file('Default', 2)
        seed_boards_from_file('Default', 3)
        seed_boards_from_file('Routines', 1)
        seed_boards_from_file('Scenarios', 1)
    end


end