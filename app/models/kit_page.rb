# A lead-magnet landing page served at /kit/:slug. Brittany creates and edits
# these in /admin; the frontend renders whatever this row says, so a new
# campaign page needs no deploy on either side.
#
# Three things are deliberately NOT here:
#
#   * The leads. A kit signup is a DownloadLead with `source = "kit_<slug>"`,
#     the same table /classroom and /ctg already use. No parallel lead model.
#   * A live board render. The download is either an existing BoardPrintable
#     plus a chosen variant, or PDFs uploaded straight onto this page — a
#     visitor gets a document an admin has already looked at, never something
#     rendered on the way out. Uploaded documents WIN: see #download_files.
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

  # A visitor's download is PDFs and only PDFs, whichever source it comes from.
  # An allowlist, never an exclusion — the same rule BoardPrintable#pdf_files
  # keeps, and for the same reason: "not an image" stops meaning "is a PDF" the
  # moment a third kind of file exists.
  DOCUMENT_CONTENT_TYPES = ["application/pdf"].freeze

  MAX_DOCUMENT_BYTES = 50.megabytes
  MAX_DOCUMENTS = 5

  # An editable Canva design a visitor gets their own copy of. The link is
  # checked against an ALLOWLIST of host and path prefix, the same rule
  # DOCUMENT_CONTENT_TYPES and KIT_IMAGE_ORDER keep: a new Canva URL shape has
  # to be opted in, never merely "not excluded".
  CANVA_HOSTS = ["canva.com", "www.canva.com"].freeze
  CANVA_PATH_PREFIX = "/design/".freeze
  MAX_TEMPLATES = 5

  # How many pages of the uploaded document are rasterized for the landing
  # page's gallery. "A couple" — the hero and one more; a visitor deciding
  # whether to hand over an email needs a look at the thing, not a page-by-page
  # tour.
  PREVIEW_PAGE_COUNT = 2

  # How long an admin's draft-preview link stays good. Short on purpose and it
  # costs nothing: the admin screen mints a fresh token every time it renders,
  # so a stale link is fixed by reloading /admin/kit_pages.
  PREVIEW_TOKEN_TTL = 24.hours

  # Namespaced so a token minted here can never be replayed against another
  # verifier's payload.
  PREVIEW_VERIFIER_PURPOSE = "kit_page_preview".freeze

  # #url_for_file (preview) / #download_url_for_file (saves the file).
  include AttachedFileUrls

  # Two NAMED attachments rather than one collection partitioned by blob
  # metadata. BoardPrintable shares a single `files` bag across PDFs, gallery
  # images and video, and the invariant in CLAUDE.md about `pdf_files` exists
  # precisely because that partition was once written as an exclusion and handed
  # a listing video to a buyer as the product. Nothing here needs a partition.
  has_many_attached :documents        # the download, when any are attached
  has_many_attached :preview_images   # rendered from documents.first

  belongs_to :board_printable, optional: true
  belongs_to :etsy_override_by, class_name: "User", optional: true

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :title, presence: true
  validates :printable_variant, inclusion: { in: VARIANTS }
  validate :content_shape
  validate :canva_templates_shape

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

  # True when this page has at least one usable Canva template link.
  def has_templates? = template_links.any?

  # Whether the page can hand ANYTHING over. Wider than `downloadable?`, which
  # keeps its narrow meaning (a readable PDF exists) — a page may offer only
  # editable templates, and the email gate has to open for it.
  def offers_anything? = downloadable? || has_templates?

  # PUBLIC. What each template IS, with no link to it. Marketing copy, on
  # exactly the argument #gallery_images makes: a photograph of the thing is
  # what persuades someone to enter an email; the thing itself is what the
  # email buys.
  def template_teasers
    usable_canva_templates.map { |row| { label: row["label"], description: row["description"].presence } }
  end

  # GATED. The same rows carrying the link, revealed only by the download
  # endpoint after a lead is written.
  def template_links
    usable_canva_templates.map do |row|
      { label: row["label"], description: row["description"].presence, url: row["url"] }
    end
  end

  # True when this page hands over documents uploaded straight onto it. Such a
  # page ignores its printable ENTIRELY — for the download and for the gallery
  # alike. A printable may still be selected (it was, before the upload), and
  # serving half of one and half of the other would put a board's marketing
  # mockups above a completely different document.
  def uploaded_download? = documents.attached? && documents.any?

  # The PDFs a visitor receives.
  def download_files
    uploaded_download? ? document_files_view : printable_download_files
  end

  # The mockup renders shown on the page — for a printable, the marketplace
  # gallery; for an uploaded document, its own first pages.
  #
  # These are MARKETING art, not the product, which is why they may sit in the
  # public read while the download may not. The rule the public payload keeps is
  # that the PDF a visitor came for is revealed only after an email; a
  # photograph of it is the thing that persuades them to enter one.
  def gallery_images
    uploaded_download? ? preview_images_view : printable_gallery_images
  end

  # One row per uploaded document, in the order they were attached.
  #
  # `variant` carries the document's LABEL because that is the field the
  # frontend prints on the button ("Download {label}", via
  # printableVariantLabel, which passes an unrecognized string straight
  # through). A single-document page shows a plain "Download" and never sees it.
  def document_files_view
    @document_files_view ||= ordered_documents.map do |file|
      {
        variant: document_label(file),
        filename: file.filename.to_s,
        url: url_for_file(file),
        byte_size: file.byte_size,
        download_url: download_url_for_file(file),
      }
    end
  end

  # The rendered pages of the uploaded document, first page first. Drops any
  # entry whose URL came back nil — `url_for_file` returns nil rather than
  # raising — exactly as the printable gallery does.
  def preview_images_view
    return [] unless preview_images.attached?

    @preview_images_view ||= preview_images
      .sort_by { |file| file.metadata["page"].to_i }
      .filter_map do |file|
        url = url_for_file(file)
        next if url.blank?

        { variant: "page_#{file.metadata["page"].to_i}", url: url }
      end
  end

  def ordered_documents
    return [] unless documents.attached?

    documents.sort_by { |file| [file.created_at, file.id] }
  end

  # The button text for one document. An admin-typed label wins; otherwise the
  # filename without its extension, which is very often already the right words.
  def document_label(file)
    file.metadata["label"].presence || File.basename(file.filename.to_s, ".*")
  end

  # Attaches one uploaded PDF at a VERSIONED key. CloudFront caches by path and
  # ignores query strings, so re-uploading over a stable key leaves the CDN
  # serving the previous document — the same lesson
  # BoardPrintable#versioned_storage_key_for records.
  def attach_document!(io:, filename:, label: nil)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: DOCUMENT_CONTENT_TYPES.first,
      key: versioned_storage_key_for(filename),
      metadata: { "label" => label.presence },
    )
    documents.attach(blob)
    reset_file_memos
    blob
  end

  def attach_preview_image!(bytes:, page:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: "preview-#{page}.png",
      content_type: "image/png",
      key: versioned_storage_key_for("preview-#{page}.png"),
      metadata: { "page" => page },
    )
    preview_images.attach(blob)
    reset_file_memos
    blob
  end

  def purge_preview_images!
    preview_images.each(&:purge)
    preview_images.reset
    preview_images_attachments.reset
    reset_file_memos
  end

  def versioned_storage_key_for(filename)
    "kit_pages/#{id}/#{SecureRandom.hex(4)}/#{filename}"
  end

  # The public payload. Deliberately carries no URL to the PRODUCT — neither a
  # file nor a Canva template link. Both are revealed only by the download
  # endpoint, after an email. Two exceptions prove the rule rather than weaken
  # it, because both are pictures of the thing rather than the thing: `images`
  # (see #gallery_images) and `templates`, which carries each template's label
  # and description and never its link (see #template_teasers).
  #
  # `content` is shipped WHOLESALE here. That is why a template's URL has its
  # own column instead of living under it.
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
      templates: template_teasers,
    }
  end

  # True when this page gives away a printable that is sold on Etsy. The admin
  # form refuses such a save until the override is confirmed.
  # A signed link that lets an admin look at a DRAFT page on the real frontend.
  #
  # The payload is the SLUG, not the id and not a bare "yes": a token minted for
  # one page must not reveal another. It expires, and it is the only thing that
  # gets an unpublished page past #for_public — being signed in as an admin does
  # not, because /kit/:slug is deliberately anonymous (the frontend sends no
  # auth header there, so a 401 can never redirect a marketing URL to sign-in).
  def preview_token
    self.class.preview_verifier.generate(slug, expires_in: PREVIEW_TOKEN_TTL)
  end

  def self.preview_verifier
    Rails.application.message_verifier(PREVIEW_VERIFIER_PURPOSE)
  end

  # True only for a live, unexpired token minted for THIS slug. Never raises —
  # a garbage token is "no", not a 500.
  def self.valid_preview_token?(slug, token)
    return false if slug.blank? || token.blank?

    preview_verifier.verified(token.to_s) == slug.to_s
  rescue StandardError
    false
  end

  # The page a public request may see. Published for everyone; unpublished only
  # with a valid preview token. An invalid token is answered exactly like a
  # missing page — a draft's existence still isn't public information.
  def self.for_public(slug, preview_token: nil)
    page = find_by(slug: slug)
    return nil if page.nil?
    return page if page.published?

    valid_preview_token?(slug, preview_token) ? page : nil
  end

  def gives_away_protected_printable? = board_printable&.protects_board? || false

  def etsy_override? = etsy_override_at.present?

  private

  # The PDFs a printable-backed page receives. `files_view` is the existing
  # PDF-only allowlist — reused rather than reimplemented so a marketing image
  # or the listing video can never be served as a download.
  #
  # Falls back to every PDF when the chosen variant isn't present, since a
  # single-board printable only ever has "full".
  def printable_download_files
    return [] unless board_printable&.complete?

    @printable_download_files ||= begin
      all = board_printable.files_view
      all.select { |file| file[:variant] == printable_variant }.presence || all
    end
  end

  # The printable's marketplace mockups — the printed sheet on a desk, the
  # flip-book, the same pages open on a tablet.
  #
  # Reuses BoardPrintable#listing_images_view, which has already dropped blobs
  # from retired gallery designs, then narrows by ALLOWLIST — never by
  # excluding what we don't want, so a new image variant has to be opted in
  # here before it can reach a visitor. `url_for_file` returns nil rather than
  # raising when a blob can't be resolved, hence the presence guard.
  def printable_gallery_images
    return [] unless board_printable&.complete?

    @printable_gallery_images ||= board_printable.listing_images_view
      .select { |image| KIT_IMAGE_ORDER.include?(image[:variant]) && image[:url].present? }
      .sort_by { |image| KIT_IMAGE_ORDER.index(image[:variant]) }
      .map { |image| { variant: image[:variant], url: image[:url] } }
  end

  # Attaching or purging inside one request leaves the views above memoized on
  # what was there before.
  def reset_file_memos
    @document_files_view = nil
    @preview_images_view = nil
  end


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

    how_to = content["how_to"]
    errors.add(:content, "how_to must be an object") if !how_to.nil? && !how_to.is_a?(Hash)
  end

  # Rows a visitor can actually be sent to. A row missing its link is dropped
  # rather than published as a dead button — the same reasoning
  # #preview_images_view uses for a blank URL.
  def usable_canva_templates
    Array(canva_templates).select { |row| row.is_a?(Hash) && row["url"].present? }
  end

  def canva_templates_shape
    return errors.add(:canva_templates, "must be a list") unless canva_templates.is_a?(Array)

    if canva_templates.size > MAX_TEMPLATES
      errors.add(:canva_templates, "can have at most #{MAX_TEMPLATES} templates")
    end

    canva_templates.each_with_index do |row, index|
      position = index + 1

      unless row.is_a?(Hash)
        errors.add(:canva_templates, "template #{position} must be an object")
        next
      end

      errors.add(:canva_templates, "template #{position} needs a label") if row["label"].blank?

      if row["url"].blank?
        errors.add(:canva_templates, "template #{position} needs a Canva link")
      elsif !canva_template_url?(row["url"])
        errors.add(:canva_templates, "template #{position} must be an https link to a Canva design")
      end
    end
  end

  def canva_template_url?(value)
    uri = URI.parse(value.to_s)
    uri.scheme == "https" &&
      CANVA_HOSTS.include?(uri.host) &&
      uri.path.to_s.start_with?(CANVA_PATH_PREFIX)
  rescue URI::InvalidURIError
    false
  end
end
