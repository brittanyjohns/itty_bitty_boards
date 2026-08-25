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
  # #url_for_file / #download_url_for_file — the preview/save URL pair.
  include AttachedFileUrls

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

  # `files` holds three kinds of blob: the printable PDFs a buyer downloads, the
  # PNG gallery images a marketplace listing needs, and the listing video. They
  # are separated by blob metadata rather than by separate attachments because
  # the PNGs arrived long after the PDFs and re-homing the existing ones would
  # have churned every stored key. Blobs written before this existed carry no
  # "kind", and are PDFs.
  KIND_PDF = "pdf".freeze
  KIND_IMAGE = "image".freeze
  KIND_VIDEO = "video".freeze

  # What counts as a buyer-facing download. An ALLOWLIST, and it has to stay
  # one: #pdf_files used to select by exclusion (`kind != KIND_IMAGE`), which
  # was correct only while "not an image" and "is a PDF" meant the same thing.
  # The moment a third kind existed the video became a PDF everywhere it
  # mattered — it would have been handed to a buyer by #files_view, uploaded to
  # Etsy as `application/pdf` against the five-file cap, and, worst because it
  # is silent, DELETED by #purge_stale_pdfs! on every "Regenerate" since the
  # video's key is never in that run's keep_keys.
  #
  # nil is in the list because blobs predating the `kind` metadata are PDFs.
  KIND_DOWNLOADABLE = [nil, KIND_PDF].freeze

  IMAGE_HERO = "hero".freeze
  IMAGE_FLIP_BOOK = "flip_book".freeze
  IMAGE_ON_A_DEVICE = "on_a_device".freeze
  IMAGE_ON_A_DEVICE_ALT = "on_a_device_alt".freeze
  IMAGE_ON_PAPER = "on_paper".freeze
  IMAGE_ON_PAPER_ALT = "on_paper_alt".freeze
  IMAGE_WHATS_INCLUDED = "whats_included".freeze
  IMAGE_ASSEMBLE = "assemble".freeze
  IMAGE_PAGE_INDEX = "page_index".freeze
  IMAGE_ABOUT = "about".freeze

  # Etsy shows gallery photos in listing order, and the first is the search
  # thumbnail. Rank 1 is a PHOTOREAL IN-USE MOCKUP, not the hero: in the shop
  # audit the listings led by a photograph of the product in a real room rated
  # "Strong" while the ones led by flat board art rated "OK/Weak". The pipeline
  # orders its own galleries the same way, for the same reason.
  #
  # Mockups and content slides alternate the whole way down. Four consecutive
  # renders of the same boards read as one product photographed four times; a
  # photo between each is what makes a buyer keep scrolling.
  #
  # This constant is the whole definition of a current gallery: adding a variant
  # here makes every previously-rendered printable stale, which is what surfaces
  # the admin badge and forces a re-render before publishing.
  #
  # TEN, which is Etsy's cap exactly. The spare slot this list used to leave for
  # a hand-made upload in the seller UI is deliberately spent on the second
  # paper mockup. A listing VIDEO occupies its own slot and does not count
  # against this. Anything added here from now on has to displace something.
  #
  # No slide here may be conditional on board count. #listing_images_current?
  # requires EVERY variant in this list, so "only render page_index for a set"
  # would leave every single-board printable permanently stale, permanently
  # badged in the admin, and re-rendering its whole gallery on every publish.
  # Where a slide means something different for one board, its COPY varies —
  # see Printables::SlideCopy — and the variant is still rendered.
  LISTING_IMAGE_ORDER = [
    # The printed sheet, in a room, at the size a buyer will actually use it.
    # This is the search thumbnail.
    IMAGE_ON_PAPER,
    IMAGE_HERO,
    # The claim a buyer is least likely to believe from text alone: that this
    # printable also opens on a screen and talks.
    IMAGE_ON_A_DEVICE,
    # The thesis. A buyer can see a stack of pages in the thumbnail; what they
    # cannot see is that the pages are LINKED — folder tiles open sub-pages and
    # every sub-page carries a way back. It is the one claim no competing AAC
    # printable can make.
    IMAGE_FLIP_BOOK,
    IMAGE_WHATS_INCLUDED,
    # A second room, a second page. The pair says "this is a thing you own",
    # where one photo alone says "this is a thing that was photographed".
    IMAGE_ON_PAPER_ALT,
    # Answers the objection the hero's count sticker creates: "so what do I do
    # with all these sheets?"
    IMAGE_ASSEMBLE,
    # A second tablet, showing a page that is NOT the front one — the answer to
    # "fine, but only the first page does that".
    IMAGE_ON_A_DEVICE_ALT,
    # The only slide on which a large set is fully legible — whats_included
    # shows thumbnails capped at ContentTilePlan::MAX_TILES and then gives up
    # with "+17 more pages".
    IMAGE_PAGE_INDEX,
    IMAGE_ABOUT,
  ].freeze

  # The listing video. One per printable — Etsy allows a listing exactly one,
  # and it occupies a slot of its own rather than counting against the ten
  # gallery photos.
  VIDEO_FLIP_THROUGH = "flip_through".freeze
  VIDEO_MANUAL = "manual".freeze

  # Bumping this marks every rendered video stale and forces a re-render, the
  # same job LISTING_IMAGE_ORDER does for the gallery. It lives in blob
  # metadata rather than a column because the alternative is a migration every
  # time the frame design changes.
  VIDEO_SPEC_VERSION = 1

  # Etsy's limits. 5-15 seconds, one video, and a listing video's audio track is
  # stripped on upload — so a clip must carry everything it says visually.
  VIDEO_MIN_SECONDS = 5.0
  VIDEO_MAX_SECONDS = 15.0

  # Retired variants. Nothing renders these any more, but printables generated
  # before each was dropped still carry the blob, and none must reach a live
  # listing. Everything that guards against them tests "not in
  # LISTING_IMAGE_ORDER" rather than matching these names, so a variant retired
  # later is caught without a code change — the constants survive only so the
  # strings are searchable and so this list records what the gallery used to be.
  #
  #   cover                  — the gallery was once a scaled-down print sheet.
  #   how_it_works           — a four-step strip sharing three of its four icons
  #                            with `assemble`; a buyer saw the same slide twice.
  #   whats_included_low_ink — the colour grid rendered a second time in full,
  #                            now a single pale page inset into that same slide.
  IMAGE_COVER = "cover".freeze
  IMAGE_HOW_IT_WORKS = "how_it_works".freeze
  IMAGE_WHATS_INCLUDED_LOW_INK = "whats_included_low_ink".freeze

  belongs_to :board
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :protection_waived_by, class_name: "User", optional: true

  # The Etsy listings made from this printable — a standalone and a bundle, say.
  # `dependent: :destroy` matches the record's existing semantics: deleting a
  # printable already leaves its Etsy drafts alone (this app implements no
  # delete call), and the confirm dialog is what warns about them.
  has_many :etsy_listings, -> { ordered },
           class_name: "BoardPrintableListing", dependent: :destroy

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
  # `listing` stamps the blob as belonging to one BoardPrintableListing. A blob
  # with no `listing_id` is the SHARED gallery every listing inherits; one with
  # a listing_id belongs to that listing alone.
  #
  # The purge is scoped the same way. It used to drop "any earlier render of
  # this variant", which the moment a listing had its own gallery would have
  # meant rendering a listing's hero deleted the shared hero — and rendering the
  # shared one deleted every listing's.
  def attach_image!(bytes:, variant:, listing: nil)
    image_files
      .select { |f| f.metadata["variant"] == variant && f.metadata["listing_id"] == listing&.id }
      .each(&:purge)
    reload_files_association

    filename = "#{variant.dasherize}-#{SecureRandom.hex(4)}.png"
    attach_blob!(
      key: storage_key_for(filename),
      filename: filename,
      bytes: bytes,
      content_type: "image/png",
      metadata: { "variant" => variant, "kind" => KIND_IMAGE, "listing_id" => listing&.id },
    )
  end

  # Same shape as #attach_image!, and versioned for the same CloudFront reason.
  # `source` distinguishes a rendered flip-through from a clip an operator
  # uploaded by hand: a hand-made clip must never be marked stale by a spec
  # bump, because nothing can re-render it.
  # `listing` scopes the clip to one listing, as it does for images — and the
  # purge is scoped with it, or attaching a listing's own clip would delete the
  # shared one every other listing inherits.
  def attach_video!(bytes:, duration:, source: VIDEO_FLIP_THROUGH, listing: nil)
    video_files.select { |f| f.metadata["listing_id"] == listing&.id }.each(&:purge)
    reload_files_association

    filename = "#{source.dasherize}-#{SecureRandom.hex(4)}.mp4"
    attach_blob!(
      key: versioned_storage_key_for(filename),
      filename: filename,
      bytes: bytes,
      content_type: VideoTranscoder::OUTPUT_CONTENT_TYPE,
      metadata: {
        "kind" => KIND_VIDEO,
        "listing_id" => listing&.id,
        "variant" => source,
        "spec_version" => VIDEO_SPEC_VERSION,
        "duration" => duration.to_f.round(2),
        "board_count" => board_ids.to_a.size,
      },
    )
  end

  # Every video blob, shared and listing-scoped alike. Callers almost always
  # want #video_files (the shared ones) or BoardPrintableListing#video_file.
  def all_video_files
    return [] unless files.attached?

    files.select { |f| f.metadata["kind"] == KIND_VIDEO }
  end

  # The SHARED clip — the one a listing inherits when it has none of its own.
  def video_files = all_video_files.select { |f| f.metadata["listing_id"].nil? }

  def video_file = video_files.first

  def listing_video? = video_file.present?

  # Whether the attached video is one this code would produce today. A
  # hand-uploaded clip is always current — there is no renderer that could
  # replace it, so badging it stale would only nag.
  def listing_video_current?
    file = video_file
    return false if file.nil?
    return true if file.metadata["variant"] == VIDEO_MANUAL

    file.metadata["spec_version"].to_i == VIDEO_SPEC_VERSION &&
      file.metadata["board_count"].to_i == board_ids.to_a.size
  end

  # Deliberately not folded into #files_view: that is the buyer's download list.
  def listing_video_view
    file = video_file
    return nil if file.nil?

    {
      variant: file.metadata["variant"],
      filename: file.filename.to_s,
      url: url_for_file(file),
      byte_size: file.byte_size,
      duration: file.metadata["duration"].to_f,
      manual: file.metadata["variant"] == VIDEO_MANUAL,
    }
  end

  # The downloadable product. Deliberately PDFs only — the admin download
  # buttons and the /api/board_printables/:id/download_url contract both read
  # this, and neither should start handing out marketing images or video.
  def files_view
    view_for(pdf_files, with_download_url: true)
  end

  # The marketplace gallery images, in the order Etsy should rank them.
  #
  # Filtered, not just sorted: a blob from a retired gallery design would
  # otherwise sort to the end and get uploaded as a real listing photo.
  def listing_images_view
    view_for(current_image_files).sort_by { |f| LISTING_IMAGE_ORDER.index(f[:variant]) }
  end

  def pdf_files
    return [] unless files.attached?

    files.select { |f| KIND_DOWNLOADABLE.include?(f.metadata["kind"].presence) }
  end

  # Every image blob, shared and listing-scoped alike.
  def all_image_files
    return [] unless files.attached?

    files.select { |f| f.metadata["kind"] == KIND_IMAGE }
  end

  # The SHARED gallery. `listing_id` absent means "every listing inherits this",
  # which is what a printable that has never had a per-listing gallery carries.
  def image_files = all_image_files.select { |f| f.metadata["listing_id"].nil? }

  def listing_images? = image_files.any?

  # Images from the gallery this code ships today, and nothing else.
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
    stale = all_image_files.reject { |f| LISTING_IMAGE_ORDER.include?(f.metadata["variant"]) }
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

  # Every board this printable covers, as records, in TREE order with the root
  # first — which is the order `board_ids` is written in and the order a
  # `where` throws away. Lives here rather than in a renderer because both the
  # gallery and the video need exactly this and a second copy would drift.
  def ordered_boards
    ids = board_ids.to_a.presence || [board_id]
    by_id = Board.where(id: ids).index_by(&:id)
    ids.filter_map { |id| by_id[id] }
  end

  # Whether this printable is CURRENTLY linked to at least one marketplace
  # listing.
  #
  # A DISPLAY predicate, not a guard. It used to be what refused a second draft
  # for the same printable; that duty now belongs to
  # BoardPrintableListing#reached_etsy?, one row at a time, because carrying two
  # listings is the point.
  #
  # The `etsy_listing_id` half covers a row published after the backfill ran but
  # before publishing started writing listing rows. It goes with the column.
  def etsy_published? = etsy_listing_id.present? || etsy_listings.any?(&:attached?)

  # The listing the printable-level API contract reports as "the" listing:
  # whichever is attached, else the first that ever reached Etsy. Every
  # printable that existed before this table has exactly one, so nothing
  # observable moves.
  def primary_etsy_listing
    reached = etsy_listings.select(&:reached_etsy?)
    reached.find(&:attached?) || reached.first
  end

  # Whether a draft was EVER created from this printable.
  #
  # A UNION of the two columns, and deliberately never narrower than the
  # `etsy_listing_id` test protection used to use: a row carrying a listing id
  # but no timestamp (set by hand, or by any path that predates the two being
  # written together) protected its boards before, and must keep protecting
  # them. Widening can only over-protect; narrowing unfreezes printed paper.
  # Must agree exactly with Boards::MarketplaceProtection::PROTECTING_SQL, which
  # asks the same question of many printables at once.
  def etsy_ever_published?
    etsy_published_at.present? || etsy_listing_id.present? || etsy_listings.any?(&:reached_etsy?)
  end

  # Whether this printable freezes the boards it was rendered from.
  #
  # Keyed on `etsy_published_at`, NOT on the record existing: generating a
  # printable to look at it is the normal way to use the admin, and locking a
  # board every time would make the feature something to avoid.
  #
  # It is also not keyed on any "is the listing still live" state, and
  # deliberately not on whether a listing is attached RIGHT NOW. The thing
  # protection defends is a printed sheet with a QR on it: ending an Etsy
  # listing doesn't un-print that sheet, and neither does detaching from it. A
  # superseded row still protects, or replacing a draft would silently unfreeze
  # boards whose printed pages are already in someone's hands — the exact
  # failure this exists to prevent. Release is the explicit waiver below.
  def protects_board? = etsy_ever_published? && protection_waived_at.nil?

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

  # Rebuild the saved listing copy from the record as it stands — which in
  # practice means "from `topic`", the only input that describes THIS product.
  #
  # Destructive on purpose: title, summary, description and tags are all
  # regenerated, so hand edits to them are lost. That is the point — the reason
  # to press it is that the generated copy is wrong because the topic was blank
  # when the printable was created, and Etsy::ListingCopy is deterministic, so
  # the only way to benefit from a new topic is to re-run it.
  #
  # Two things it deliberately keeps:
  #
  #   price_cents — not topic-derived at all (the generator emits a constant),
  #                 so regenerating would silently reset a price someone chose.
  #   any other key — merged over rather than replaced, so a key the generator
  #                 doesn't emit (the TPT overrides listing_copy_params folds
  #                 back in) survives. Same discipline as that method.
  def regenerate_listing_copy!
    existing = listing_copy.to_h
    generated = Etsy::ListingCopy.new(self).build
    generated["price_cents"] = existing["price_cents"] if existing["price_cents"].present?

    update!(listing_copy: existing.merge(generated))
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

  # `with_download_url` is opt-in rather than always-on: only the buyer-facing
  # PDF list needs a "save this" link, and #listing_images_view would otherwise
  # sign a URL per gallery image that nothing ever follows.
  def view_for(collection, with_download_url: false)
    collection.map do |file|
      entry = {
        variant: file.metadata["variant"].presence || VARIANT_FULL,
        filename: file.filename.to_s,
        url: url_for_file(file),
        byte_size: file.byte_size,
      }
      entry[:download_url] = download_url_for_file(file) if with_download_url
      entry
    end
  end

  # `url_for_file` (preview) and `download_url_for_file` (presigned, saves the
  # file) live in AttachedFileUrls — KitPage's uploaded documents need the same
  # pair, and the presign path is too subtle to keep two copies of.
end
