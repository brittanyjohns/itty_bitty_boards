class BoardExport < ApplicationRecord
  STATUSES = %w[queued processing completed failed].freeze

  belongs_to :user
  belongs_to :exportable, polymorphic: true

  # Production explicitly selects the private/presigned S3 service
  # (`amazon_private` in config/storage.yml — same bucket/credentials as the
  # public `amazon` service, minus `public: true`) so `#download`'s
  # `file.url(...)` redirect is a genuinely signed, expiring URL rather than
  # the public bucket's permanent unauthenticated one. These .obz/.obf files
  # can bundle a family's own audio recordings, so per-request access control
  # matters here in a way it doesn't for most other public: true assets.
  #
  # Every other environment keeps using whatever service is already
  # configured as the app default (Disk in dev/test) completely unaffected —
  # `Rails.application.config.active_storage.service` is evaluated fresh
  # each time, so this doesn't hardcode dev/test's service name.
  has_one_attached :file, service: Rails.env.production? ? :amazon_private : Rails.application.config.active_storage.service

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  # Genuinely in-flight exports, bounded by a staleness window. Without the
  # time bound, a BoardExport that never reaches ExportBoardPackageJob's
  # rescue blocks (OOM, hard kill) stays "processing" forever and permanently
  # 409-locks that user out of exporting with no recovery route. 30 minutes
  # is a generous ceiling — a 200-board/200MB package could legitimately take
  # several minutes — with no other job-timeout convention elsewhere in the
  # codebase to match instead.
  IN_FLIGHT_STATUSES = %w[queued processing].freeze
  IN_FLIGHT_STALENESS = 30.minutes

  scope :in_flight, -> { where(status: IN_FLIGHT_STATUSES).where(created_at: IN_FLIGHT_STALENESS.ago..) }

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
