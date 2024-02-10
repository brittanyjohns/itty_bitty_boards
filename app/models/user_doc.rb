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
end
