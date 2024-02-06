module SeedHelper

    def parent_resource
        @parent_resource ||= ParentResource.first
    end

    def admin_user
        @admin_user ||= User.admins.first
    end

    def seed_boards_from_file(filename = 'board_data.json')
        board_data = json_data(filename)
        new_images = []
        board_data.each do |category, words|
            puts "Creating board for #{category} - parent_resource: #{parent_resource.id} - admin_user: #{admin_user.id}"
            board = Board.find_or_create_by!(name: category, parent: parent_resource, user_id: admin_user.id)
            words.each do |word|
                puts "Creating image for #{word}"
                image = Image.public_img.find_or_create_by!(label: word.downcase)
                new_images << image
                board.add_image(image.id)
            end
        end
        @new_images = new_images
    end

    def json_data(filename = 'board_data.json')
        File.open(Rails.root.join('db', 'seed_data', filename)) do |file|
            JSON.load(file)
        end
    end

end