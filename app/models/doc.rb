class Doc < ApplicationRecord
  belongs_to :documentable, polymorphic: true
  has_one_attached :image
end
