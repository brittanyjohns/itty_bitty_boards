class ImportFromObzJob
  include Sidekiq::Job
  # json_input = { extracted_obz_data: extracted_obz_data, current_user_id: current_user&.id, group_name: file_name, root_board_id: @root_board_id }
  def perform(board_data, user_id)
    current_user = User.find_by(id: user_id)
    return unless current_user
    unless board_data.is_a?(Hash)
      Rails.logger.error "Invalid board data provided for import: #{board_data.class.name}"
      return
    end
    Rails.logger.debug "Importing from OBZ file - Job started for user ID #{current_user.id}"
    Rails.logger.debug("Board data: #{board_data.inspect}")

    importer = ObzImporter.new(board_data, current_user)
    if importer.import
      Rails.logger.info "OBZ import completed successfully for user ID #{current_user.id}"
    else
      Rails.logger.error "OBZ import failed for user ID #{current_user.id}"
    end
  rescue => e
    Rails.logger.error "Error during OBZ import: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
