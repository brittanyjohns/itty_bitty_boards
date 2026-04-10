# == Schema Information
#
# Table name: user_docs
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  doc_id     :bigint           not null
#  image_id   :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class UserDoc < ApplicationRecord
  belongs_to :user
  belongs_to :doc
  belongs_to :image, optional: true

  def api_view
    {
      id: id,
      user_id: user_id,
      doc_id: doc_id,
      url: doc.tile_url,
      src: doc.tile_url,
      image_id: image_id,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
