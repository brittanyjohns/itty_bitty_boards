namespace :boards do
  desc "Update board images to use default doc URLs. Example usage: BOARD_IDS=1,2,3 rails boards:update_images"
  task update_images: :environment do
    LIMIT = ENV["LIMIT"] ? ENV["LIMIT"].to_i : 5
    board_ids = ENV["BOARD_IDS"] ? ENV["BOARD_IDS"].split(",").map(&:to_i) : nil
    user_id = ENV["USER_ID"] ? ENV["USER_ID"].to_i : nil
    boards = if board_ids
        Board.where(id: board_ids).order(updated_at: :asc)
      elsif user_id
        Board.where(user_id: user_id).order(updated_at: :asc)
      else
        puts "No BOARD_IDS or USER_ID provided, defaulting to all public boards"
        Board.public_boards.order(updated_at: :asc)
      end
    boards = board_ids ? Board.where(id: board_ids) : boards
    puts "Updating BoardImages for #{boards.count} boards"
    puts "LIMIT is set to #{LIMIT}" if LIMIT
    puts "BOARD_IDS is set to #{board_ids.join(",")}" if board_ids
    puts "USER_ID is set to #{user_id}" if user_id

    puts "About to update BoardImages to default doc URLs..."
    puts "Are you sure you want to proceed? (yes/no)"
    answer = STDIN.gets.chomp
    unless answer.downcase == "yes"
      puts "Aborting..."
      next
    end

    boards.limit(LIMIT).find_each do |board|
      puts "Updating Board ID #{board.id} - #{board.name}"
      board.update_board_images_to_default_docs!
      board.update_column(:updated_at, Time.current) # update timestamp to reflect change
    end
    puts "Done updating BoardImages"
  end
end
