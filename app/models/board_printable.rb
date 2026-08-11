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

  # `files` holds two kinds of blob: the printable PDFs a buyer downloads, and
  # the PNG gallery images a marketplace listing needs. They are separated by
  # blob metadata rather than a second attachment because the PNGs arrived long
  # after the PDFs and re-homing the existing ones would have churned every
  # stored key. Blobs written before this existed carry no "kind", and are PDFs.
  KIND_PDF = "pdf".freeze
  KIND_IMAGE = "image".freeze

  IMAGE_COVER = "cover".freeze
  IMAGE_WHATS_INCLUDED = "whats_included".freeze
  # Etsy shows gallery photos in listing order; the cover earns rank 1.
  LISTING_IMAGE_ORDER = [IMAGE_COVER, IMAGE_WHATS_INCLUDED].freeze

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
    attach_blob!(
      filename: filename,
      bytes: bytes,
      content_type: "application/pdf",
      metadata: { "variant" => variant, "kind" => KIND_PDF },
    )
  end

  # Unlike the PDFs, a listing image is written to a VERSIONED key: CloudFront
  # ignores query strings, so re-uploading to the same key leaves the admin
  # looking at the previous render and wondering why "Regenerate" did nothing.
  # Same lesson as Boards::GeneratePreviewAssets. Any earlier render of this
  # variant is purged first so the versioned keys can't pile up.
  def attach_image!(bytes:, variant:)
    image_files.select { |f| f.metadata["variant"] == variant }.each(&:purge)
    reload_files_association

    filename = "#{variant.dasherize}-#{SecureRandom.hex(4)}.png"
    attach_blob!(
      filename: filename,
      bytes: bytes,
      content_type: "image/png",
      metadata: { "variant" => variant, "kind" => KIND_IMAGE },
    )
  end

  # The downloadable product. Deliberately PDFs only — the admin download
  # buttons and the /api/board_printables/:id/download_url contract both read
  # this, and neither should start handing out marketing images.
  def files_view
    view_for(pdf_files)
  end

  # The marketplace gallery images, in the order Etsy should rank them.
  def listing_images_view
    view_for(image_files).sort_by { |f| LISTING_IMAGE_ORDER.index(f[:variant]) || LISTING_IMAGE_ORDER.size }
  end

  def pdf_files
    return [] unless files.attached?

    files.select { |f| f.metadata["kind"].presence != KIND_IMAGE }
  end

  def image_files
    return [] unless files.attached?

    files.select { |f| f.metadata["kind"] == KIND_IMAGE }
  end

  def listing_images? = image_files.any?

  def etsy_published? = etsy_listing_id.present?

  # The copy an admin has saved, or the generated default when nothing has been
  # saved yet — so the show page can preview a listing before anyone edits it.
  def listing_copy_or_default
    listing_copy.presence || Etsy::ListingCopy.new(self).build
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

  # `files` is memoized once loaded, so a purge inside a multi-step render is
  # invisible to the next `files.find` without this.
  def reload_files_association
    files.reset
    files_attachments.reset
  end

  def attach_blob!(filename:, bytes:, content_type:, metadata:)
    key = storage_key_for(filename)
    # Purge anything already at the deterministic key first, same reason as
    # MarketingAsset#attach_pdf! — create_and_upload! would otherwise collide.
    files.find { |f| f.key == key }&.purge

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: content_type,
      key: key,
      metadata: metadata,
    )
    files.attach(blob)
    blob
  end

  def view_for(collection)
    collection.map do |file|
      {
        variant: file.metadata["variant"].presence || VARIANT_FULL,
        filename: file.filename.to_s,
        url: url_for_file(file),
        byte_size: file.byte_size,
      }
    end
  end

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
