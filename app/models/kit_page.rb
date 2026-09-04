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
  # checked against an ALLOWLIST of host and path, the same rule
  # DOCUMENT_CONTENT_TYPES and KIT_IMAGE_ORDER keep: a new Canva URL shape has
  # to be opted in, never merely "not excluded".
  #
  # Canva's Share menu hands out TWO shapes and both are legitimate — the full
  # design URL, and a `canva.link` short link that 301s to one. Neither is
  # rewritten on the way in: the shortener is Canva's own, a visitor following
  # it lands in the same place, and resolving it here would make saving the
  # admin form depend on a third-party request that can hang or fail.
  CANVA_DESIGN_HOSTS = ["canva.com", "www.canva.com"].freeze
  CANVA_DESIGN_PATH_PREFIX = "/design/".freeze
  CANVA_SHORT_HOSTS = ["canva.link"].freeze
  MAX_TEMPLATES = 5

  # What one rendered page may be. `hidden` is not "deleted" — the render still
  # exists and the admin can promote it later; it simply isn't published.
  PREVIEW_PUBLIC = "public".freeze
  PREVIEW_GATED = "gated".freeze
  PREVIEW_HIDDEN = "hidden".freeze
  PREVIEW_VISIBILITIES = [PREVIEW_PUBLIC, PREVIEW_GATED, PREVIEW_HIDDEN].freeze

  # How many pages of EVERY uploaded document are rasterized so an admin has
  # something to choose from.
  DEFAULT_PREVIEW_RENDER_LIMIT = 10

  # How many rendered pages are PUBLIC when an admin has chosen nothing. A
  # different number from the one above and deliberately unchanged: an empty
  # `preview_settings` has to leave a live page exactly as it was.
  DEFAULT_PUBLIC_PREVIEW_COUNT = 2

  # Read at CALL time, never stamped — the same rule every other ENV-tunable
  # limit in this app keeps, so raising it is a Hatchbox change and not a deploy.
  def self.preview_render_limit
    ENV.fetch("KIT_PREVIEW_RENDER_LIMIT", DEFAULT_PREVIEW_RENDER_LIMIT).to_i
  end

  # The key one rendered page is remembered by. Keyed on the document's BLOB id
  # rather than its attachment id or its filename: the attachment id is a join
  # row, and two documents can share a filename — which is why uploads already
  # go to a versioned key.
  def self.preview_setting_key(document_id, page) = "#{document_id}:#{page}"

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
    uploaded_download? ? public_preview_images : printable_gallery_images
  end

  # The gallery as it stands AFTER the email. A printable-backed page has
  # nothing gated, so it answers with the same list it already published.
  def released_gallery_images
    uploaded_download? ? released_preview_images : printable_gallery_images
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

  # EVERY rendered page, in document order then page order, each carrying the
  # document it came from and its resolved visibility. The admin picker, the
  # public gallery and the post-email handover are all filters over this one
  # list, so the three can never disagree about what a page is.
  #
  # Drops any entry whose URL came back nil — `url_for_file` returns nil rather
  # than raising — exactly as the printable gallery does.
  def preview_rows
    return [] unless preview_images.attached?

    @preview_rows ||= build_preview_rows
  end

  # The admin picker's rows: everything, hidden pages included.
  def preview_picker_rows = preview_rows

  # PUBLIC. The rendered pages a visitor sees before entering an email.
  def public_preview_images = serialized_previews(PREVIEW_PUBLIC)

  # GATED + PUBLIC. What the download endpoint hands over, so the page can swap
  # its gallery after capture without a second request. Public rows are included
  # rather than diffed out: the frontend replaces the whole list, and the ones it
  # already had must keep their position in it.
  def released_preview_images = serialized_previews(PREVIEW_PUBLIC, PREVIEW_GATED)

  # True once an admin has curated. An empty hash is "never asked", which is a
  # different thing from "everything hidden" and resolves to the historical
  # default instead.
  def previews_curated? = preview_settings.present?

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

  # One rendered page.
  #
  # `document_id` and `batch` are OPTIONAL, and nil is meaningful in both: a
  # preview with no document id is attributed to the first document (which is
  # what every preview rendered before multi-document support actually was), and
  # a preview with no batch reads as the current one. That is what lets this
  # change deploy without a backfill and without blanking a live gallery.
  def attach_preview_image!(bytes:, page:, document_id: nil, batch: nil)
    filename = document_id ? "preview-#{document_id}-#{page}.png" : "preview-#{page}.png"
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: "image/png",
      key: versioned_storage_key_for(filename),
      metadata: { "page" => page, "document_id" => document_id, "batch" => batch }.compact,
    )
    preview_images.attach(blob)
    reset_file_memos
    blob
  end

  # `except_batch:` is what makes a re-render render-then-purge rather than
  # purge-then-render. Purging first blanks the public gallery for as long as the
  # job runs, which was a second at two pages and is a minute at fifty.
  def purge_preview_images!(except_batch: nil)
    doomed = preview_images.reject { |file| except_batch.present? && file.metadata["batch"] == except_batch }
    return if doomed.empty?

    doomed.each(&:purge)
    preview_images.reset
    preview_images_attachments.reset
    reset_file_memos
  end

  # Records which rendered pages show where. Writes only keys that name a page
  # this record actually has, and only values from PREVIEW_VISIBILITIES — the
  # form is the injection surface, and a key naming another page's document has
  # no business here.
  #
  # Settings for documents that are still attached but whose render hasn't landed
  # yet are PRESERVED, and settings for documents that are gone are pruned. A
  # wholesale replacement would silently lose the first; a plain merge would never
  # do the second.
  def update_preview_settings!(submitted)
    allowed = preview_rows.index_by { |row| row[:key] }

    cleaned = Hash(submitted.respond_to?(:to_unsafe_h) ? submitted.to_unsafe_h : submitted)
      .each_with_object({}) do |(key, value), acc|
        next unless allowed.key?(key.to_s)
        next unless PREVIEW_VISIBILITIES.include?(value.to_s)

        acc[key.to_s] = value.to_s
      end

    update!(preview_settings: live_preview_settings.merge(cleaned))
    reset_file_memos
    preview_settings
  end

  # Drops settings whose document has been removed. Called when a document is
  # purged so a deleted file's choices don't sit in the column forever.
  def prune_preview_settings!
    kept = live_preview_settings
    return preview_settings if kept.size == preview_settings.size

    update!(preview_settings: kept)
    reset_file_memos
    preview_settings
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
    @preview_rows = nil
  end

  # The settings hash with every entry whose document is gone dropped.
  def live_preview_settings
    live = ordered_documents.map(&:blob_id).map(&:to_s).to_set
    preview_settings.select { |key, _| live.include?(key.to_s.split(":").first.to_s) }
  end

  # The batch every preview in the CURRENT set carries. Legacy previews carry no
  # batch at all, and nil is the max of an all-nil set, so they read as current
  # until the first re-render replaces them.
  def current_preview_batch
    preview_images.filter_map { |file| file.metadata["batch"].presence }.max
  end

  def build_preview_rows
    documents = ordered_documents
    return [] if documents.empty?

    positions = {}
    labels = {}
    documents.each_with_index do |document, index|
      positions[document.blob_id.to_s] = index
      labels[document.blob_id.to_s] = document_label(document)
    end

    batch = current_preview_batch
    default_document_id = documents.first.blob_id.to_s

    preview_images
      .select { |file| file.metadata["batch"].presence == batch }
      .filter_map { |file| preview_row_for(file, positions, labels, default_document_id) }
      .sort_by { |row| [row[:document_position], row[:page]] }
  end

  def preview_row_for(file, positions, labels, default_document_id)
    # No document id means this render predates multi-document support, when the
    # only document rendered WAS the first one.
    document_id = file.metadata["document_id"].presence&.to_s || default_document_id
    position = positions[document_id]
    return nil if position.nil? # its document has been removed

    url = url_for_file(file)
    return nil if url.blank?

    page = file.metadata["page"].to_i
    key = self.class.preview_setting_key(document_id, page)

    {
      key: key,
      document_id: document_id,
      document_position: position,
      document_label: labels[document_id],
      page: page,
      url: url,
      visibility: resolved_preview_visibility(key, position, page),
    }
  end

  # An empty `preview_settings` is "never asked" and answers with the historical
  # default. Once it is non-empty a key that isn't in it is HIDDEN — a page that
  # shows up later (a new upload, a raised render limit) must never publish
  # itself.
  def resolved_preview_visibility(key, document_position, page)
    if previews_curated?
      preview_settings[key].to_s.presence_in(PREVIEW_VISIBILITIES) || PREVIEW_HIDDEN
    elsif document_position.zero? && page <= DEFAULT_PUBLIC_PREVIEW_COUNT
      PREVIEW_PUBLIC
    else
      PREVIEW_HIDDEN
    end
  end

  def serialized_previews(*visibilities)
    preview_rows
      .select { |row| visibilities.include?(row[:visibility]) }
      .map { |row| { variant: "page_#{row[:page]}", url: row[:url], page: row[:page], label: preview_label(row) } }
  end

  # What the picture IS, for alt text and the enlarged view's caption. The
  # document's name is only worth saying when there is more than one — on a
  # single-document page it is noise on every tile.
  def preview_label(row)
    return "Page #{row[:page]}" if ordered_documents.size < 2

    "#{row[:document_label]} — page #{row[:page]}"
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
        errors.add(
          :canva_templates,
          "template #{position} must be an https canva.com/design/… or canva.link/… link",
        )
      end
    end
  end

  def canva_template_url?(value)
    uri = URI.parse(value.to_s)
    return false unless uri.scheme == "https"

    if CANVA_DESIGN_HOSTS.include?(uri.host)
      uri.path.to_s.start_with?(CANVA_DESIGN_PATH_PREFIX)
    elsif CANVA_SHORT_HOSTS.include?(uri.host)
      # The shortener's entire path IS the id, so there is no prefix to check —
      # only that the link names something rather than the bare domain.
      uri.path.to_s.delete_prefix("/").present?
    else
      false
    end
  rescue URI::InvalidURIError
    false
  end
end
