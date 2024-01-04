class Doc < ApplicationRecord
  belongs_to :documentable, polymorphic: true
  has_one_attached :image

  scope :current, -> { where(current: true) }

  def label
    documentable.label
  end
end
