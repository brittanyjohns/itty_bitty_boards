class ExportBoardPackageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 1

  def perform(board_export_id)
    record = BoardExport.find_by(id: board_export_id)
    return unless record

    record.mark_processing!

    scope = case record.exportable
      when BoardGroup then Boards::ExportScope.for_group(record.exportable, exporting_user: record.user)
      else Boards::ExportScope.for_board(record.exportable, exporting_user: record.user)
      end

    result = Boards::ObzPackager.new(scope, exporting_user: record.user).call

    record.file.attach(
      io: StringIO.new(result.bytes),
      filename: "#{record.exportable.name.to_s.parameterize.presence || "boards"}.obz",
      content_type: "application/zip",
    )

    settings = record.settings.is_a?(Hash) ? record.settings.dup : {}
    settings["exported_to_obf"] = result.summary
    record.update!(status: "completed", settings: settings)
  rescue Boards::ObzPackager::TooLarge => e
    # Actionable by the user (split the set), so surface it rather than the
    # generic message.
    Rails.logger.warn "[ExportBoardPackageJob] #{e.message}"
    record&.mark_failed!(e.message)
  rescue StandardError => e
    Rails.logger.error "[ExportBoardPackageJob] #{e.class}: #{e.message}"
    record&.mark_failed!("Export failed")
  end
end
