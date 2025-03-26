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
  default_scope { where(deleted_at: nil) }
  belongs_to :user, optional: true
  belongs_to :documentable, polymorphic: true, touch: true
  belongs_to :board, optional: true
  has_one_attached :image
  has_one_base64_attached :image
  has_many :user_docs, dependent: :destroy

  after_create :update_user_docs, if: :user_id

  scope :current, -> { where(current: true) }
  scope :image_docs, -> { where(documentable_type: "Image") }
  scope :menu_docs, -> { where(documentable_type: "Menu") }
  scope :created_yesterday, -> { where("created_at > ?", 1.day.ago) }
  scope :created_today, -> { where("created_at > ?", 1.day.ago) }
  scope :hidden, -> { unscope(:where).where.not(deleted_at: nil) }
  scope :not_hidden, -> { where(deleted_at: nil) }
  scope :symbols, -> { where(source_type: "OpenSymbol") }
  scope :ai_generated, -> { where(source_type: "OpenAI") }
  # scope :with_attached_image, -> { includes(image_attachment: :blob) }
  scope :without_attached_image, -> { where.missing(:image_attachment) }
  scope :no_user, -> { where(user_id: nil) }
  scope :with_user, -> { where.not(user_id: nil) }

  def hide!
    update(deleted_at: Time.now)
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
      prompt_for_prompt: prompt_for_prompt,
      data: data,
      license: license,
      documentable_type: documentable_type,
      documentable_id: documentable_id,
      src: display_url,
    }
  end

  def extension
    original_image_url&.split(".")&.last
    # image&.blob&.filename.to_s&.split(".")&.last
  end

  def active_storage_to_data_url
    # blob = image.blob
    # puts "Blob: #{blob}"
    # # Get S3 URL
    # url = Rails.application.routes.url_helpers.rails_blob_url(blob, only_path: false)
    # # Download and encode
    # image_data = URI.open(url).read
    # mime_type = blob.content_type # e.g., "image/png"
    # base64_image = Base64.strict_encode64(image_data)
    # "data:#{mime_type};base64,#{base64_image}"
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
  end

  def self.admin_default_id
    User::DEFAULT_ADMIN_ID
  end

  def self.for_user(user)
    if user.nil?
      return self.with_attached_image.where(user_id: [nil, User::DEFAULT_ADMIN_ID])
    end
    # user.admin? ? self.all : self.with_attached_image.where(user_id: [user.id, nil, admin_default_id])
    self.with_attached_image.where(user_id: [user.id, nil, admin_default_id])
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

  def self.with_matching_label(label)
    self.preload(:documentable).joins
  end

  def self.matching_doc_urls_for_label(label)
    docs = self.with_matching_label(label)

    docs.map(&:display_url)
  end

  def image_url
    matching_open_symbols.first&.image_url
  end

  include Rails.application.routes.url_helpers

  def display_url
    return original_image_url if !image.attached?
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
