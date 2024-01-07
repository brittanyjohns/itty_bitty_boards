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
#
class Doc < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :documentable, polymorphic: true
  belongs_to :board, optional: true
  has_one_attached :image

  before_save :update_current
  after_commit :update_doc_list

  scope :current, -> { where(current: true) }

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
    broadcast_update_to(:doc_list, inserts_by: :append, target: "#{self.documentable_id}_docs_list", partial: "docs/doc", collection: documentable.docs)
  end
    
end
