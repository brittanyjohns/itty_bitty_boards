# == Schema Information
#
# Table name: docs
#
#  id                 :bigint           not null, primary key
#  documentable_type  :string           not null
#  documentable_id    :bigint           not null
#  processed          :text
#  raw                :text
#  current            :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  board_id           :integer
#  user_id            :integer
#  source_type        :string
#  deleted_at         :datetime
#  original_image_url :string
#  prompt_for_prompt  :string
#  data               :jsonb
#  license            :jsonb
#
class Doc < ApplicationRecord
  # A doc uploaded by a person through a user-facing endpoint, as opposed to a
  # generated, imported or scraped one ("OpenAI", "OpenSymbol", "ObfImport",
  # "GoogleSearch").
  #
  # `source_type` is provenance, and provenance decides what we may do with the
  # bytes — see `Images::CommercialLicense`. Assign it EXPLICITLY at each
  # creation site; never default it on the model. A blank source_type means
  # "unknown", which fails closed; labelling unknown provenance as USER would
  # assert that a user owns content they may not, which is the one direction
  # that fails unsafely.
  SOURCE_TYPE_USER = "User".freeze

  # A tile picture we rendered ourselves from text the user typed — see
  # Images::TextTile. No third party is involved: the glyphs come from an OFL
  # font (which licenses the font software, not the pixels it draws), so the
  # bytes are ours to export and to sell. Both license services treat it the
  # same way they treat "OpenAI".
  SOURCE_TYPE_TEXT_TILE = "SpeakAnyWayText".freeze

  default_scope { where(deleted_at: nil) }
  belongs_to :user, optional: true
  belongs_to :documentable, polymorphic: true, touch: true
  belongs_to :board, optional: true
  has_one_attached :image
  has_one_base64_attached :image
  has_many :user_docs, dependent: :destroy

  # A likeness doc is drawn for one tile's look; an automatic UserDoc pick would
  # make it the owner's picture for that word on every other board they have.
  after_create :update_user_docs, if: -> { user_id && !likeness? }

  # data keys stamped on art generated with a communicator likeness
  # (Images::LikenessResolver). The fingerprint identifies the look for reuse;
  # the traits and age band are the TAG — which personalization drew it, as
  # allowlisted tokens and never the communicator it was drawn for.
  #
  # A likeness doc is PICKABLE, never a DEFAULT: an admin-owned one is library
  # (listed for everyone, and a user may choose it), but generic resolution
  # (Image#display_doc's fallback), docs.current and images.src_url never land
  # on one — NOT_LIKENESS_SQL is the filter those paths use.
  LIKENESS_KEY = "likeness_fingerprint".freeze
  LIKENESS_TRAITS_KEY = "likeness_traits".freeze
  LIKENESS_AGE_BAND_KEY = "likeness_age_band".freeze
  NOT_LIKENESS_SQL = "docs.data->>'#{LIKENESS_KEY}' IS NULL".freeze

  scope :current, -> { where(current: true) }
  scope :image_docs, -> { where(documentable_type: "Image") }
  scope :menu_docs, -> { where(documentable_type: "Menu") }
  scope :created_yesterday, -> { where("created_at > ?", 1.day.ago) }
  scope :created_today, -> { where("created_at > ?", 1.day.ago) }
  scope :hidden, -> { unscope(:where).where.not(deleted_at: nil) }
  scope :not_hidden, -> { where(deleted_at: nil) }
  scope :symbols, -> { where(source_type: "OpenSymbol") }
  scope :ai_generated, -> { where(source_type: "OpenAI") }
  scope :user_uploaded, -> { where(source_type: SOURCE_TYPE_USER) }
  scope :without_attached_image, -> { where.missing(:image_attachment) }
  scope :no_user, -> { where(user_id: nil) }
  scope :with_user, -> { where.not(user_id: nil) }

  # Rendering a variant writes its bytes from an `after_commit` callback, but
  # image_processing's output tempfile is closed AND UNLINKED the moment the
  # transform block returns (`Transformer#transform` ends in `output.close!`).
  # With an application transaction open, that callback is deferred to the
  # OUTER commit — long after the tempfile is gone — and the upload dies on
  # `Errno::ENOENT @ rb_file_s_size - /tmp/image_processing*.webp`, taking the
  # whole job with it. So a variant is only ever rendered with no transaction
  # open; anywhere else the render is queued for after the commit.
  #
  # This is Rails' own predicate for "would a callback registered now be
  # deferred": it counts only JOINABLE open transactions, so the non-joinable
  # wrapper transactional fixtures hold open doesn't make every spec defer.
  def self.variant_render_safe?
    ActiveRecord.all_open_transactions.empty?
  end

  def tile_variant
    return unless image.attached?
    return unless image.variable?

    image.variant(TILE_VARIANT_TRANSFORMATIONS)
  end

  # Renders the 288px tile variant when it is safe to do so right now, and
  # queues it for after the commit otherwise. Returns whether the variant is
  # on the service by the time this returns.
  def ensure_tile_variant!
    return false unless image.attached?
    return false unless image.variable?
    return true if tile_variant_processed?

    unless self.class.variant_render_safe?
      queue_tile_variant_render!
      return false
    end

    tile_variant&.processed
    true
  end

  # Never a bare `perform_async`: the doc row this names may not be committed
  # yet, and a worker reading on its own connection can dequeue first and find
  # nothing. Outside a transaction the block runs immediately.
  def queue_tile_variant_render!
    doc_id = id
    ActiveRecord.after_all_transactions_commit do
      PreprocessDocTileVariantJob.perform_async(doc_id)
    end
  end

  def tile_variant_processed?
    return false unless image.attached?
    return false unless image.variable?
    return false unless image.blob.respond_to?(:variant_records)

    variant = tile_variant
    return false unless variant

    image.blob.variant_records.where(
      variation_digest: variant.variation.digest,
    ).exists?
  rescue => e
    Rails.logger.warn("[tile-variant] processed? check failed for Doc #{id}: #{e.message}")
    false
  end

  def tile_url
    return original_image_url unless image.attached?
    return display_url unless image.variable?

    variant = tile_variant
    return display_url unless variant
    # Serving the full-resolution original is correct, just larger — and it is
    # a real URL, which matters: a blank display_image_url is the marker for
    # "this tile has no picture". display_url queues the render for after the
    # commit.
    return display_url unless tile_variant_processed? || self.class.variant_render_safe?

    processed_variant = variant.processed

    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        "#{cdn_host}/#{processed_variant.key}"
      else
        Rails.application.routes.url_helpers.url_for(processed_variant)
      end
    else
      Rails.application.routes.url_helpers.url_for(processed_variant)
    end
  rescue => e
    Rails.logger.warn("[tile-url] error doc=#{id}: #{e.message}")
    display_url
  end

  def hide!
    update(deleted_at: Time.now)
  end

  def list_api_view(viewing_user = nil)
    {
      id: id,
      raw: raw,
      can_edit: user_id == viewing_user&.id,
      processed: processed,
      current: current,
      created_at: created_at,
      updated_at: updated_at,
      board_id: board_id,
      user_id: user_id,
      source_type: source_type,
      original_image_url: original_image_url,
      data: data,
      license: license,
      documentable_type: documentable_type,
      documentable_id: documentable_id,
      likeness: likeness_tag,
      src: display_url,
    # tile_src: tile_url,
    }
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      raw: raw,
      can_edit: user_id == viewing_user&.id,
      processed: processed,
      current: current,
      created_at: created_at,
      updated_at: updated_at,
      board_id: board_id,
      user_id: user_id,
      source_type: source_type,
      original_image_url: original_image_url,
      # prompt_for_prompt: prompt_for_prompt,
      data: data,
      license: license,
      documentable_type: documentable_type,
      documentable_id: documentable_id,
      likeness: likeness_tag,
      src: tile_url,
    # tile_src: tile_url,
    }
  end

  def extension
    original_image_url&.split(".")&.last
    # image&.blob&.filename.to_s&.split(".")&.last
  end

  def active_storage_to_data_url
    url = display_url
    downloaded_image = Down.download(url)
    image_data = downloaded_image.read
    mime_type = downloaded_image.content_type # e.g., "image/png"
    base64_image = Base64.strict_encode64(image_data)
    "data:#{mime_type};base64,#{base64_image}"
  end

  def self.update_source_types
    missing_documentable = []
    self.all.each do |doc|
      if doc.documentable.nil?
        missing_documentable << doc
        puts "Doc #{doc.id} has no documentable"
        doc.destroy
        next
      end
      doc.update(source_type: "OpenAI")
    end
    self.created_yesterday.each do |doc|
      doc.update(source_type: "OpenSymbol")
    end
    puts "Missing documentable: #{missing_documentable.count}\n#{missing_documentable.inspect}"
  end

  def menu?
    documentable.is_a?(Menu)
  end

  def update_user_docs
    return unless user_id
    if image?
      user_docs.where(user_id: user_id, image_id: documentable_id).first_or_create
    end
  end

  def image?
    documentable.is_a?(Image)
  end

  def self.missing_image
    self.where.missing(:image_attachment)
  end

  def self.create_missing_images(max = 5)
    count = 0
    wait_time = 0
    self.image_docs.missing_image.each do |doc|
      doc.documentable.start_generate_image_job(wait_time)
      count += 1
      break if count >= max
    end
  end

  def create_image
    if documentable.is_a?(Image)
      image = documentable
    else
      image = documentable.create_image
    end
    self.image.attach(io: File.open(image.file_path), filename: image.file_name)
    queue_tile_variant_render!
  end

  def self.admin_default_id
    User::DEFAULT_ADMIN_ID
  end

  # The docs a viewer may see: their own, plus LIBRARY docs (owned by nil or
  # DEFAULT_ADMIN_ID). A doc owned by any other user is private to that user —
  # Images are shared rows, their docs are not. `#visible_to?` is the in-memory
  # mirror, for filtering an already-loaded association without a query.
  #
  # An admin-owned likeness doc is library like any other admin doc — listed for
  # everyone and pickable. This is a VISIBILITY answer only: a caller resolving
  # a default adds `.where(NOT_LIKENESS_SQL)`. A likeness doc owned by anyone
  # else stays private to its owner.
  def self.for_user(user)
    library = where(user_id: [nil, User::DEFAULT_ADMIN_ID])
    scope = user.nil? ? library : library.or(where(user_id: user.id))
    scope.with_attached_image
  end

  def library?
    user_id.nil? || user_id == User::DEFAULT_ADMIN_ID
  end

  def likeness?
    data.is_a?(Hash) && data[LIKENESS_KEY].present?
  end

  # A likeness picture in the shared library: any user may pick it for
  # themselves, and nothing may make it the word's default.
  def shared_likeness?
    likeness? && library?
  end

  # The data keys a generation stamps for a resolved likeness
  # (Images::LikenessResolver::Result), or {} when there is none. Traits are
  # tokens and the age band only — never the communicator, since an admin
  # likeness doc is visible to every account.
  def self.likeness_data(likeness)
    return {} if likeness.nil? || likeness.likeness.blank?

    {
      LIKENESS_KEY => likeness.fingerprint,
      LIKENESS_TRAITS_KEY => likeness.likeness.to_h,
      LIKENESS_AGE_BAND_KEY => likeness.age_band.presence,
    }.compact
  end

  # Which personalization drew this picture, for a picker to show. nil for an
  # ordinary doc, and for a likeness doc generated before traits were stamped
  # (its fingerprint is a one-way hash and names no look).
  def likeness_tag(locale = I18n.locale)
    traits = data.is_a?(Hash) ? data[LIKENESS_TRAITS_KEY] : nil
    return nil unless traits.is_a?(Hash)

    likeness = CommunicatorLikeness.from_hash(traits)
    return nil if likeness.blank?

    age_band = data[LIKENESS_AGE_BAND_KEY].presence
    {
      traits: likeness.to_h,
      age_band: age_band,
      label: likeness.label(locale: locale, age_band: age_band),
    }
  end

  def visible_to?(viewer)
    library? || (viewer.present? && user_id == viewer.id)
  end

  def self.current_for_user(user)
    for_user(user).current
  end

  def display_description
    documentable.display_description
  end

  def label
    documentable&.label || "Doc #{id}"
  end

  def menu_doc?
    documentable&.is_a?(Menu)
  end

  def update_current
    @documentable = documentable
    if !@documentable.docs.current.any?
      self.current = true
    end
  end

  def matching_open_symbols
    OpenSymbol.where(search_string: raw)
  end

  def image_url
    matching_open_symbols.first&.image_url
  end

  include Rails.application.routes.url_helpers

  def tile_variant_done?
    tile_variant_processed?
  end

  def display_url
    return original_image_url if !image.attached?
    queue_tile_variant_render! unless tile_variant_processed?
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        "#{cdn_host}/#{image.key}" # Construct CloudFront URL
      else
        image.url # Fallback to the direct Active Storage URL
      end
    else
      image.url
    end
  end

  def self.clean_up_broken_urls
    broken_count = 0
    no_blob_count = 0
    broken_docs = []

    self.all.each do |doc|
      puts "No display URL: #{doc.id}" if doc.display_url.nil?
      if doc.display_url.nil?
        broken_count += 1
        broken_docs << doc
      end
    end

    broken_docs.each do |doc|
      doc.hide! # Soft delete instead of hard delete
    end

    puts "Broken Count: #{broken_count}"
    puts "No Blob Count: #{no_blob_count}"
    puts "Total Docs: #{self.all.count}"
    puts "Broken Docs: #{broken_docs.count}"
  end

  def is_a_favorite?(user)
    UserDoc.where(user_id: user.id, doc_id: id).any?
  end

  def update_doc_list
    broadcast_update_to(:doc_list, inserts_by: :append, target: "#{self.documentable_id}_docs_list", partial: "docs/doc", collection: documentable.docs, locals: { doc: self, viewing_user: self.user })
  end
end
