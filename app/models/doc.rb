# == Schema Information
#
# Table name: docs
#
#  id                :bigint           not null, primary key
#  documentable_type :string           not null
#  documentable_id   :bigint           not null
#  raw_text          :text
#  processed_text    :text
#  current           :boolean          default(FALSE)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  board_id          :integer
#  user_id           :integer
#
class Doc < ApplicationRecord
  default_scope { includes(:image_attachment) }
  belongs_to :user, optional: true
  belongs_to :documentable, polymorphic: true
  belongs_to :board, optional: true
  has_one_attached :image
  has_many :user_docs, dependent: :destroy

  after_create :update_user_docs, if: :user_id

  scope :current, -> { where(current: true) }
  scope :image_docs, -> { where(documentable_type: "Image") }
  scope :menu_docs, -> { where(documentable_type: "Menu") }
  scope :created_yesterday, -> { where("created_at > ?", 1.day.ago) }

  # def self.with_no_user_docs_for(user_id)
  #   includes(:user_docs).
  #     references(:user_docs).
  #     where.not(user_docs: { user_id: user_id })
  # end

  def self.update_source_types
    self.all.each do |doc|
      doc.update(source_type: "OpenAI")
    end
    self.created_yesterday.each do |doc|
      doc.update(source_type: "OpenSymbol")
    end
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

  def self.with_attached_images
    self.with_attached_image.all
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
    user.admin? ? self.all : self.where(user_id: [user.id, nil, admin_default_id])
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

  def is_a_favorite?(user)
    UserDoc.where(user_id: user.id, doc_id: id).any?
  end

  def update_doc_list
    broadcast_update_to(:doc_list, inserts_by: :append, target: "#{self.documentable_id}_docs_list", partial: "docs/doc", collection: documentable.docs, locals: { doc: self, viewing_user: self.user })
  end
    
end
