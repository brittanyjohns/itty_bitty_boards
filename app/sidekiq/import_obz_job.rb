# app/sidekiq/import_obz_job.rb
#
# Async half of the .obz import (POST /api/boards/import_obf). The controller
# does the synchronous pre-work — creates the BoardGroup with
# status: "queued", attaches the uploaded .obz to it via ActiveStorage (raw
# zip bytes don't belong in a Sidekiq/Redis job payload) — and enqueues this
# job. Everything ObzImporter does (unzipping, creating each board, matching/
# attaching images) runs here instead of blocking the request.
#
# Status lifecycle mirrors BuildBoardSetJob/GenerateBoardJob so the frontend's
# existing BoardGenerationStatusPage polling works unmodified: "queued" ->
# "processing" -> "complete"/"failed" (re-raised after marking failed so
# Sidekiq's single configured retry gets a chance).
class ImportObzJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(board_group_id, user_id, import_options = {})
    board_group = BoardGroup.find_by(id: board_group_id)
    unless board_group
      Rails.logger.error "ImportObzJob: BoardGroup with ID #{board_group_id} not found."
      return
    end

    current_user = User.find_by(id: user_id)
    unless current_user
      Rails.logger.error "ImportObzJob: User with ID #{user_id} not found for BoardGroup #{board_group_id}."
      board_group.update_column(:status, "failed")
      return
    end

    unless board_group.import_source_file.attached?
      Rails.logger.error "ImportObzJob: no import_source_file attached to BoardGroup #{board_group_id}."
      board_group.update_column(:status, "failed")
      return
    end

    board_group.update_column(:status, "processing")

    bytes = board_group.import_source_file.download
    result = ObzImporter.new(
      bytes, current_user,
      board_group: board_group, import_all: true,
      import_options: (import_options || {}).symbolize_keys,
    ).import!

    if result[:root_board]
      board_group.update_column(:status, "complete")
      board_group.import_source_file.purge
    else
      board_group.update_column(:status, "failed")
    end
  rescue => e
    Rails.logger.error "\n**** SIDEKIQ - ImportObzJob #{board_group_id} \n\nERROR **** \n#{e.message}\n#{e.backtrace&.join("\n")}\n"
    board_group&.update_column(:status, "failed")
    raise
  end
end
