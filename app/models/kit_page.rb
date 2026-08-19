# A lead-magnet landing page served at /kit/:slug. Brittany creates and edits
# these in /admin; the frontend renders whatever this row says, so a new
# campaign page needs no deploy on either side.
#
# Three things are deliberately NOT here:
#
#   * The leads. A kit signup is a DownloadLead with `source = "kit_<slug>"`,
#     the same table /classroom and /ctg already use. No parallel lead model.
#   * The file. The download is an existing BoardPrintable plus a chosen
#     variant, so a visitor gets the same reviewed document the admin looked at
#     rather than a live board render.
#   * The gate. Production S3 is `public: true`, so every printable already sits
#     behind a permanent unsigned CDN URL and the hex path segment is the only
#     protection. Asking for an email before revealing that URL is a soft gate
#     on purpose — exactly what /classroom does today.
class KitPage < ApplicationRecord
  # Same kebab-case rule as MarketingAsset::SLUG_FORMAT — these slugs end up in
  # a public URL and in a Mailchimp tag, so neither may carry punctuation.
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # Leads are discriminated by this prefix everywhere `DownloadLead#source` is
  # read, notably MailchimpUpsertLeadJob's dynamic tag lookup.
  LEAD_SOURCE_PREFIX = "kit_".freeze

  # A subboard bundle carries the three DOWNLOAD_VARIANTS; a single-board
  # printable carries one "full" document holding all of them.
  VARIANTS = (BoardPrintable::DOWNLOAD_VARIANTS + [BoardPrintable::VARIANT_FULL]).freeze

  # The mockups a visitor sees, in landing-page order. A curated ALLOWLIST of
  # the Etsy gallery rather than the whole of it: `about` is shop framing and
  # `page_index` answers an objection only a buyer has, so both read wrong on a
  # page that is giving the thing away.
  KIT_IMAGE_ORDER = [
    BoardPrintable::IMAGE_HERO,
    BoardPrintable::IMAGE_ON_PAPER,
    BoardPrintable::IMAGE_FLIP_BOOK,
    BoardPrintable::IMAGE_WHATS_INCLUDED,
    BoardPrintable::IMAGE_ON_A_DEVICE,
  ].freeze

  belongs_to :board_printable, optional: true
  belongs_to :etsy_override_by, class_name: "User", optional: true

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :title, presence: true
  validates :printable_variant, inclusion: { in: VARIANTS }
  validate :content_shape

  scope :published, -> { where(published: true) }

  # Resolve the page a `kit_<slug>` lead source came from. Returns nil for any
  # other source, and for a page that has since been deleted.
  def self.for_lead_source(source)
    slug = source.to_s
    return nil unless slug.start_with?(LEAD_SOURCE_PREFIX)

    published_or_not = slug.delete_prefix(LEAD_SOURCE_PREFIX)
    return nil if published_or_not.blank?

    find_by(slug: published_or_not)
  end

  def lead_source = "#{LEAD_SOURCE_PREFIX}#{slug}"

  # `camelize` alone leaves the hyphen in place ("at-school" -> "At-school"),
  # which is not a usable Mailchimp tag — so the slug is underscored first.
  def resolved_mailchimp_tag
    mailchimp_tag.presence || "#{slug.to_s.tr("-", "_").camelize}Lead"
  end

  # Whether the page can actually hand a file over. Keyed on there being a
  # readable PDF, not merely on a printable being selected: a page whose
  # printable is still generating (or which only carries listing images) must
  # tell the frontend to hide the email form rather than render a gate that
  # 422s on submit.
  def downloadable? = download_files.any?

  # The PDFs a visitor receives. `files_view` is the existing PDF-only
  # allowlist — reused rather than reimplemented so a marketing image or the
  # listing video can never be served as a download.
  #
  # Falls back to every PDF when the chosen variant isn't present, since a
  # single-board printable only ever has "full".
  def download_files
    return [] unless board_printable&.complete?

    @download_files ||= begin
      all = board_printable.files_view
      all.select { |file| file[:variant] == printable_variant }.presence || all
    end
  end

  # The mockup renders shown on the page — the printed sheet on a desk, the
  # flip-book, the same pages open on a tablet.
  #
  # These are MARKETING art, not the product, which is why they may sit in the
  # public read while `download_files` may not. The rule the public payload
  # keeps is that the PDF a visitor came for is revealed only after an email;
  # a photograph of it is the thing that persuades them to enter one.
  #
  # Reuses BoardPrintable#listing_images_view, which has already dropped blobs
  # from retired gallery designs, then narrows by ALLOWLIST — never by
  # excluding what we don't want, so a new image variant has to be opted in
  # here before it can reach a visitor. `url_for_file` returns nil rather than
  # raising when a blob can't be resolved, hence the presence guard.
  def gallery_images
    return [] unless board_printable&.complete?

    @gallery_images ||= board_printable.listing_images_view
      .select { |image| KIT_IMAGE_ORDER.include?(image[:variant]) && image[:url].present? }
      .sort_by { |image| KIT_IMAGE_ORDER.index(image[:variant]) }
      .map { |image| { variant: image[:variant], url: image[:url] } }
  end

  # The public payload. Deliberately carries no file URL — the URL is revealed
  # only by the download endpoint, after an email. `images` is the exception
  # that proves it: see #gallery_images.
  def public_view
    {
      slug: slug,
      title: title,
      eyebrow: eyebrow,
      subhead: subhead,
      content: content.presence || {},
      cta_label: cta_label,
      cta_path: cta_path,
      downloadable: downloadable?,
      images: gallery_images,
    }
  end

  # True when this page gives away a printable that is sold on Etsy. The admin
  # form refuses such a save until the override is confirmed.
  def gives_away_protected_printable? = board_printable&.protects_board? || false

  def etsy_override? = etsy_override_at.present?

  private

  # Loose on purpose: the frontend renders whatever it finds and the admin
  # edits this as JSON, so the only thing worth refusing is a shape that would
  # make the renderer throw.
  def content_shape
    return errors.add(:content, "must be a JSON object") unless content.is_a?(Hash)

    # Keyed on nil, not on `present?` — an empty array is a fine "no items",
    # but an empty array under "closing" is still the wrong type.
    items = content["items"]
    if !items.nil? && !(items.is_a?(Array) && items.all?(Hash))
      errors.add(:content, "items must be a list of objects")
    end

    closing = content["closing"]
    errors.add(:content, "closing must be an object") if !closing.nil? && !closing.is_a?(Hash)
  end
end
