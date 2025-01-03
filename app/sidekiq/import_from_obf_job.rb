class ImportFromObfJob
  include Sidekiq::Job

  def perform(json_data)
    puts "Importing from OBZ file"
    data = JSON.parse(json_data)
    extracted_obz_data = data["extracted_obz_data"]
    puts "Extracted OBZ data: #{extracted_obz_data}"
    current_user = User.find(data["current_user_id"])
    group_name = data["group_name"]
    @root_board_id = data["root_board_id"]
    puts "@root_board_id: #{@root_board_id}"

    created_boards = Board.from_obz(extracted_obz_data, current_user, group_name, @root_board_id)
    puts "Created boards: #{created_boards}"
    if created_boards.present?
      Rails.logger.info "Imported boards from OBZ file: group_name: #{group_name}, root_board_id: #{@root_board_id}"
    else
      Rails.logger.error "Failed to import boards from OBZ file: group_name: #{group_name}, root_board_id: #{@root_board_id}"
    end
    # Do something
  end
end
