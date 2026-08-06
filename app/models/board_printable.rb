# A cover-wrapped, print-ready PDF generated from a board (optionally the
# board plus its whole subboard tree). Admin-only; this is the in-app port of
# the speakanyway-printables pipeline's PDF-producing core.
#
# One attachment for a single board (the 6-page document), two for a subboard
# bundle (a colour variant and a low-ink variant, each fully wrapped).
#
# Deliberately NOT `board.pdf_file` — that's the existing single-page cached
# board export and it's exposed through Board#api_view.
class BoardPrintable < ApplicationRecord
  STATUSES = %w[pending generating complete failed].freeze

  DEFAULT_MAX_BOARDS = 25
  # A hard ceiling on what an admin may ask for. Every board in the tree is
  # two Grover renders, so an unbounded max_boards is a way to hang a Sidekiq
  # worker for hours by typo.
  MAX_BOARDS_CEILING = 100

  # The single-board document carries both the colour and the low-ink page,
  # so it is neither variant — it's the whole printable.
  VARIANT_FULL = "full".freeze
  VARIANT_COLOR = "color".freeze
  VARIANT_LOW_INK = "low_ink".freeze

  belongs_to :board
  belongs_to :created_by, class_name: "User", optional: true

  has_many_attached :files

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def complete? = status == "complete"

  def mark_generating! = update!(status: "generating")

  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(1000))
  end

  # Scoped by record id so re-running for the same board never collides on the
  # unique index over active_storage_blobs.key.
  def storage_key_for(filename) = "board_printables/#{id}/#{filename}"

  def attach_pdf!(filename:, bytes:, variant:)
    key = storage_key_for(filename)
    # Purge anything already at the deterministic key first, same reason as
    # MarketingAsset#attach_pdf! — create_and_upload! would otherwise collide.
    files.find { |f| f.key == key }&.purge

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: "application/pdf",
      key: key,
      metadata: { "variant" => variant },
    )
    files.attach(blob)
    blob
  end

  def files_view
    return [] unless files.attached?

    files.map do |file|
      {
        variant: file.metadata["variant"].presence || VARIANT_FULL,
        filename: file.filename.to_s,
        url: url_for_file(file),
        byte_size: file.byte_size,
      }
    end
  end

  def api_view
    {
      id: id,
      status: status,
      board_id: board_id,
      include_subboards: include_subboards,
      page_count: page_count,
      error_message: error_message,
      files: files_view,
    }
  end

  private

  # Production S3 is `public: true`, so the URL is CDN_HOST + key rather than
  # a presigned one — same convention as Board#pdf_url and
  # MarketingAsset#file_url. Never raises: a download URL must not break the
  # status response.
  def url_for_file(file)
    cdn_host = ENV["CDN_HOST"]
    return "#{cdn_host}/#{file.key}" if cdn_host.present?

    file.url
  rescue => e
    Rails.logger.warn("BoardPrintable#url_for_file failed for #{id}: #{e.class}: #{e.message}")
    nil
  end
end
