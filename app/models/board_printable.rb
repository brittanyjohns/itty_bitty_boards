# A cover-wrapped, print-ready PDF generated from a board (optionally the
# board plus its whole subboard tree). Admin-only; this is the in-app port of
# the speakanyway-printables pipeline's PDF-producing core.
#
# One attachment for a single board (one document holding every variant of the
# page), three for a subboard bundle (colour, low-ink and trim-ready, each
# fully wrapped).
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

  # The single-board document carries the colour, low-ink and trim-ready pages
  # together, so it is none of those variants — it's the whole printable.
  VARIANT_FULL = "full".freeze
  VARIANT_COLOR = "color".freeze
  VARIANT_LOW_INK = "low_ink".freeze
  # Full colour with the print header replaced by a corner QR: the board fills
  # the sheet, and the code survives a buyer trimming the page down before
  # laminating it. Ships alongside the other two, never instead of them.
  VARIANT_TRIM_READY = "trim_ready".freeze

  # Order is the order the files are attached, listed in the admin, and
  # uploaded to a marketplace — colour first, because it's the one a buyer
  # prints if they only print one.
  DOWNLOAD_VARIANTS = [VARIANT_COLOR, VARIANT_LOW_INK, VARIANT_TRIM_READY].freeze

  # `files` holds two kinds of blob: the printable PDFs a buyer downloads, and
  # the PNG gallery images a marketplace listing needs. They are separated by
  # blob metadata rather than a second attachment because the PNGs arrived long
  # after the PDFs and re-homing the existing ones would have churned every
  # stored key. Blobs written before this existed carry no "kind", and are PDFs.
  KIND_PDF = "pdf".freeze
  KIND_IMAGE = "image".freeze

  IMAGE_HERO = "hero".freeze
  IMAGE_ON_A_DEVICE = "on_a_device".freeze
  IMAGE_WHATS_INCLUDED = "whats_included".freeze
  IMAGE_WHATS_INCLUDED_LOW_INK = "whats_included_low_ink".freeze
  IMAGE_HOW_IT_WORKS = "how_it_works".freeze
  IMAGE_ABOUT = "about".freeze

  # Etsy shows gallery photos in listing order, and the first is the search
  # thumbnail — so the hero, which is the only one that shows the actual boards,
  # earns rank 1. The low-ink slide sits straight after the colour one so the
  # two read as a pair rather than as two different products.
  #
  # This constant is the whole definition of a current gallery: adding a variant
  # here makes every previously-rendered printable stale, which is what surfaces
  # the admin badge and forces a re-render before publishing.
  LISTING_IMAGE_ORDER = [
    IMAGE_HERO,
    # Rank 2: the claim a buyer scrolling an Etsy gallery is least likely to
    # believe from text alone is that this printable also opens on a screen and
    # talks. It goes before the inventory slides.
    IMAGE_ON_A_DEVICE,
    IMAGE_WHATS_INCLUDED,
    IMAGE_WHATS_INCLUDED_LOW_INK,
    IMAGE_HOW_IT_WORKS,
    IMAGE_ABOUT,
  ].freeze

  # The gallery used to be a scaled-down print sheet: a "cover" plus a
  # what's-included slide. Nothing renders a cover any more, but printables
  # generated before the redesign still carry the blob, and it must not reach a
  # live listing — hence the name survives here and nowhere else. Everything
  # that guards against it tests "not in LISTING_IMAGE_ORDER" rather than
  # matching this, so a variant retired later is caught without a code change.
  IMAGE_COVER = "cover".freeze

  belongs_to :board
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :protection_waived_by, class_name: "User", optional: true

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

  # The same, with a version segment ahead of the filename — so the buyer-facing
  # download name is untouched while the path a CDN caches on is new.
  def versioned_storage_key_for(filename)
    "board_printables/#{id}/#{SecureRandom.hex(4)}/#{filename}"
  end

  # A regenerated PDF must land on a NEW key. Production serves these straight
  # off CloudFront (CDN_HOST + the blob key, see #url_for_file) and CloudFront
  # caches by path while ignoring query strings, so re-uploading the fresh
  # document to the deterministic key left "Regenerate" looking like a no-op:
  # the admin, and anything else holding the URL, kept getting the previous PDF
  # long after the board had changed. Same lesson as #attach_image! and
  # Boards::GeneratePreviewAssets.
  #
  # The version lives in the key PATH rather than the filename because the
  # filename is the product's name on a marketplace download — a buyer should
  # not receive "core-words-9f2a.pdf". Superseded versions are cleaned up by
  # #purge_stale_pdfs! once the new files are attached.
  def attach_pdf!(filename:, bytes:, variant:)
    attach_blob!(
      key: versioned_storage_key_for(filename),
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
      key: storage_key_for(filename),
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
  #
  # Filtered, not just sorted: a blob from the retired two-image gallery would
  # otherwise sort to the end and get uploaded as a real listing photo.
  def listing_images_view
    view_for(current_image_files).sort_by { |f| LISTING_IMAGE_ORDER.index(f[:variant]) }
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

  # Images from the current four-slide gallery only.
  def current_image_files
    image_files.select { |f| LISTING_IMAGE_ORDER.include?(f.metadata["variant"]) }
  end

  # Whether the gallery on this printable is the one we ship today. A printable
  # carrying only the retired cover/what's-included pair has images, but not
  # ones that should go anywhere near a listing — so "has images" is not a
  # strong enough guard for publishing.
  def listing_images_current?
    variants = current_image_files.map { |f| f.metadata["variant"] }
    LISTING_IMAGE_ORDER.all? { |variant| variants.include?(variant) }
  end

  # PDFs left over from an earlier generation of this same record. Every re-run
  # writes to a fresh versioned key (see #attach_pdf!), so this is what keeps a
  # regenerated printable from accumulating one downloadable file per run — and
  # it is the only thing that removes the superseded document, which is exactly
  # why it must be handed THIS run's keys rather than matching on filename.
  # Purged AFTER the new files are attached, so a failed re-render never empties
  # the record.
  def purge_stale_pdfs!(keep_keys)
    stale = pdf_files.reject { |f| keep_keys.include?(f.key) }
    return if stale.empty?

    stale.each(&:purge)
    reload_files_association
  end

  # Blobs from a retired gallery design. Purged after a re-render rather than
  # before it, so a render that fails leaves the old images in place instead of
  # emptying the gallery.
  def purge_legacy_listing_images!
    stale = image_files.reject { |f| LISTING_IMAGE_ORDER.include?(f.metadata["variant"]) }
    return if stale.empty?

    stale.each(&:purge)
    reload_files_association
  end

  # The BOARD pages a buyer gets, which is what listing copy quotes.
  #
  # `page_count` is the true length of the merged PDFs and every file is
  # wrapped in a cover, a how-to-use page, a license and a credits page — so it
  # sold a one-board printable, whose three board pages are the whole product,
  # as a "7-page board PDF". A buyer counts the boards they can print, not the
  # front matter.
  #
  # Derived rather than stamped at generation time because CollectPages renders
  # each board exactly once per download variant: the count is exact for
  # printables generated before this existed, with no re-render.
  def board_page_count = board_ids.to_a.size * DOWNLOAD_VARIANTS.size

  def etsy_published? = etsy_listing_id.present?

  # Whether this printable freezes the boards it was rendered from.
  #
  # Keyed on `etsy_listing_id`, NOT on the record existing: generating a
  # printable to look at it is the normal way to use the admin, and locking a
  # board every time would make the feature something to avoid. It is also not
  # keyed on any "is the listing still live" state — the thing protection
  # defends is a printed sheet with a QR on it, and ending an Etsy listing
  # doesn't un-print that sheet. Release is the explicit waiver below.
  def protects_board? = etsy_published? && protection_waived_at.nil?

  def protection_waived? = protection_waived_at.present?

  def waive_protection!(user:, reason: nil)
    update!(
      protection_waived_at: Time.current,
      protection_waived_by: user,
      protection_waived_reason: reason.presence,
    )
  end

  # Every board this printable was rendered from — the root plus each page of
  # the tree. `board_ids` is written by Boards::Printables::Generate; the root
  # is unioned in because a printable that failed before that write still has a
  # real `board_id`.
  def protected_board_ids = (board_ids.to_a + [board_id]).compact.uniq

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

  def attach_blob!(key:, filename:, bytes:, content_type:, metadata:)
    # Purge anything already at this key first, same reason as
    # MarketingAsset#attach_pdf! — create_and_upload! would otherwise collide.
    # Versioned keys can't collide, so this only ever fires for the images.
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
