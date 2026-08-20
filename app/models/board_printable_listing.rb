# One Etsy listing made from a BoardPrintable.
#
# A printable can carry several — a standalone listing and a bundle listing, say
# — each with its own copy, its own gallery selection and its own PDF subset,
# all serving the same rendered document. Before this existed the listing WAS
# four scalar columns on `board_printables`, so a printable could hold one
# listing at a time and reaching a second one meant NULLing the first.
#
# Two things this row is, that the columns could not be:
#
#   * A publish TOKEN. The row is created `pending`, before anything touches
#     Etsy, and a compare-and-set on `state` claims it exactly once. That is how
#     a double-click, a double-enqueue or a hand-run Sidekiq retry are stopped
#     from creating a second draft in a real shop.
#   * A permanent RECORD. Detaching supersedes the row and KEEPS the listing id,
#     because this app implements no delete call — the draft is still on Etsy
#     and someone has to be told which one to go and remove.
class BoardPrintableListing < ApplicationRecord
  # pending    — allocated, nothing sent to Etsy yet. Deletable.
  # publishing — claimed by a job. Only the job may move it off this.
  # published  — a draft exists on Etsy. `etsy_listing_id` is set.
  # failed     — the publish stopped before `create_listing` returned. Nothing
  #              was created; the same claim accepts a retry.
  # superseded — detached. The id is kept; the draft is still on Etsy.
  STATES = %w[pending publishing published failed superseded].freeze

  # Free text lives in `label`; this is only the coarse kind, so the admin list
  # can be read at a glance.
  PURPOSES = %w[standalone bundle variant].freeze

  # What `pdf_variants` may name. The variant, not the ActiveStorage key: a key
  # is versioned per generation run, so an allowlist of keys empties itself on
  # the first "Regenerate" and the listing silently reverts to shipping
  # everything.
  PDF_VARIANTS = (BoardPrintable::DOWNLOAD_VARIANTS + [BoardPrintable::VARIANT_FULL]).freeze

  belongs_to :board_printable
  belongs_to :created_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }
  validates :purpose, inclusion: { in: PURPOSES }
  validate :allowlists_are_known

  scope :ordered, -> { order(:created_at, :id) }

  # The rows that have touched Etsy. Deliberately a UNION of the two columns and
  # deliberately NOT filtered on `superseded_at` — this is what marketplace
  # protection reads, and a detached listing still protects: ending or replacing
  # a listing does not un-print the paper carrying these boards' QR codes.
  scope :reached_etsy, -> { where("etsy_listing_id IS NOT NULL OR published_at IS NOT NULL") }

  # A draft exists on Etsy for THIS row. The single thing that refuses a second
  # publish of the same row — the duty BoardPrintable#etsy_published? used to
  # carry for the whole printable.
  def reached_etsy? = etsy_listing_id.present? || published_at.present?

  # Attached to a live listing right now: a draft exists and nobody detached it.
  def attached? = etsy_listing_id.present? && superseded_at.nil?

  def superseded? = superseded_at.present?

  # The draft exists but not everything reached it. Distinguishable only because
  # the id is persisted the instant Etsy returns it, before any upload — which
  # is what stops a half-built draft becoming an orphan.
  def assets_incomplete? = published_at.present? && assets_uploaded_at.nil?

  # Overrides merged over the printable's base copy. Blank values fall back
  # rather than publishing an empty title, so clearing a field in the form means
  # "use the printable's" and not "send nothing".
  def resolved_copy
    board_printable.listing_copy_or_default.to_h.stringify_keys
                   .merge(listing_copy.to_h.stringify_keys.compact_blank)
  end

  # ---- Assets -------------------------------------------------------------
  #
  # Every partition below is an ALLOWLIST over the printable's shared set, never
  # an exclusion. That is the same rule BoardPrintable::KIND_DOWNLOADABLE holds:
  # selecting by "not the thing I don't want" was correct only while there were
  # two kinds of blob, and the moment a third existed the video was served to
  # buyers as a PDF. A per-listing subset must not become a second way round it.

  # This listing's gallery: its own rendered slides if it has any, else the
  # shared ones. Then narrowed and ordered by `image_variants` — empty means
  # "all of them", which is what every listing starts with.
  # The slides rendered FOR this listing, as opposed to the shared gallery it
  # would otherwise inherit.
  def own_image_files
    board_printable.all_image_files.select { |f| f.metadata["listing_id"] == id }
  end

  # A topic override changes what the slides SAY, so a listing carrying one
  # needs a gallery of its own — the renderer builds every slide from the boards
  # and the topic, so inheriting the shared gallery would leave the override
  # doing nothing at all.
  def own_gallery_required? = topic_override.present?

  def image_files
    files = own_image_files.presence || board_printable.current_image_files
    files = files.select { |f| BoardPrintable::LISTING_IMAGE_ORDER.include?(f.metadata["variant"]) }
    files = files.select { |f| selected_image_variants.include?(f.metadata["variant"]) } if
      selected_image_variants.any?

    # Sorted here rather than at the upload site: rank 1 is Etsy's search
    # thumbnail, and every reader of this list wants the same order.
    files.sort_by { |f| BoardPrintable::LISTING_IMAGE_ORDER.index(f.metadata["variant"]) }
  end

  # INTERSECTED with the printable's `pdf_files`, which is the allowlist that
  # keeps a gallery image or the listing video from ever being handed to a buyer
  # as the product. Never a fresh selection over `files`.
  def pdf_files
    files = board_printable.pdf_files
    return files if selected_pdf_variants.empty?

    files.select { |f| selected_pdf_variants.include?(f.metadata["variant"]) }
  end

  # This listing's own clip if it has one, else the shared one.
  def video_file
    board_printable.all_video_files.find { |f| f.metadata["listing_id"] == id } ||
      board_printable.video_file
  end

  def listing_video? = video_file.present?

  # Whether this listing's gallery is the one this code ships today. Only its
  # SELECTED variants have to be there — a listing that deliberately ships six
  # slides is not stale for missing the other four.
  def listing_images_current?
    return false if own_gallery_required? && own_image_files.empty?

    have = image_files.map { |f| f.metadata["variant"] }
    (selected_image_variants.presence || BoardPrintable::LISTING_IMAGE_ORDER).all? { |v| have.include?(v) }
  end

  # Rank 1 is Etsy's search thumbnail, and the shop audit is unambiguous about
  # what belongs there: a photoreal in-use mockup. `about` and `page_index` are
  # shop framing and an objection-handler — leading with either is the mistake
  # this ordering exists to prevent.
  def first_image_variant = image_files.first&.metadata&.dig("variant")

  def selected_image_variants
    Array(image_variants) & BoardPrintable::LISTING_IMAGE_ORDER
  end

  def selected_pdf_variants
    Array(pdf_variants) & PDF_VARIANTS
  end

  # Feeds the gallery renderer, which builds its slides from the boards and the
  # topic — never from `listing_copy`. Overriding the topic is the only lever
  # that makes two listings of one printable render different images.
  def resolved_topic = topic_override.presence || board_printable.topic

  # Etsy allows one video per listing and this app implements no call that can
  # read a listing back, so this stamp is the only memory that makes a second
  # POST at the SAME listing refusable. It is per row because the rule is per
  # listing: the same clip going to a standalone and a bundle is correct.
  def can_push_video? = attached? && video_pushed_at.nil?

  def mark_video_pushed!
    update_columns(video_pushed_at: Time.current, updated_at: Time.current)
  end

  # Detach WITHOUT forgetting.
  #
  # Keeps `etsy_listing_id` so the admin can still be told which draft to delete
  # on Etsy — the old #relist! NULLed it and left the draft unfindable. Keeps
  # `video_pushed_at` too: that was true of THIS listing, and a replacement is a
  # different row whose stamp is nil by construction.
  def supersede!
    update!(state: "superseded", superseded_at: Time.current)
  end

  private

  # A typo'd variant would silently drop a slide or a download file from a live
  # listing, which is the kind of failure nobody looks for.
  def allowlists_are_known
    unknown_images = Array(image_variants) - BoardPrintable::LISTING_IMAGE_ORDER
    unknown_pdfs = Array(pdf_variants) - PDF_VARIANTS

    errors.add(:image_variants, "has unknown variants: #{unknown_images.join(", ")}") if unknown_images.any?
    errors.add(:pdf_variants, "has unknown variants: #{unknown_pdfs.join(", ")}") if unknown_pdfs.any?
  end
end
