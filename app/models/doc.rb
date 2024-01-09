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
  belongs_to :user, optional: true
  belongs_to :documentable, polymorphic: true
  belongs_to :board, optional: true
  has_one_attached :image

  before_save :update_current
  # after_commit :update_doc_list

  scope :current, -> { where(current: true) }
  scope :image_docs, -> { where(documentable_type: "Image") }
  scope :menu_docs, -> { where(documentable_type: "Menu") }

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

  def for_user(user)
    where(user_id: [user.id, nil])
  end

  # def file_name
  #   "#{label}.png"
  # end

  # def file_path
  #   Rails.root.join("tmp", "images", file_name)
  # end

  # def image_url
  #   image.attached? ? Rails.application.routes.url_helpers.rails_blob_url(image, only_path: true) : nil
  # end

  # def image_tag
  #   image.attached? ? ActionController::Base.helpers.image_tag(image_url) : nil
  # end

  # def image_tag_with_label
  #   image_tag ? "#{image_tag} #{label}" : label
  # end

  # def image_tag_with_label_and_link
  #   image_tag ? "#{ActionController::Base.helpers.link_to(image_tag, image_url)} #{label}" : label
  # end

  # def image_tag_with_label_and_link_and_description
  #   image_tag ? "#{ActionController::Base.helpers.link_to(image_tag, image_url)} #{label} #{display_description}" : label
  # end

  def display_description
    documentable.display_description
  end

  def label
    documentable.label
  end

  def menu_doc?
    documentable&.is_a?(Menu)
  end

  def update_current
    @documentable = documentable
    if !@documentable.docs.current.any?
      self.current = true
    end
    # self.user_id = @documentable.user_id if @documentable.user_id && self.user_id.blank?
  end

  def update_doc_list
    broadcast_update_to(:doc_list, inserts_by: :append, target: "#{self.documentable_id}_docs_list", partial: "docs/doc", collection: documentable.docs, locals: { doc: self, viewing_user: self.user })
  end
    
end
