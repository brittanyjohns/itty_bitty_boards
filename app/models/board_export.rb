class BoardExport < ApplicationRecord
  STATUSES = %w[queued processing completed failed].freeze

  belongs_to :user
  belongs_to :exportable, polymorphic: true
  has_one_attached :file

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def completed? = status == "completed"

  def mark_processing! = update!(status: "processing")

  def mark_failed!(message)
    update!(status: "failed", error_message: message)
  end

  def api_view
    {
      id: id,
      status: status,
      file_format: file_format,
      error_message: error_message,
      download_url: (Rails.application.routes.url_helpers.download_api_board_export_path(self) if completed? && file.attached?),
      summary: settings["exported_to_obf"],
      created_at: created_at,
    }
  end
end
