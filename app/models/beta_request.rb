# == Schema Information
#
# Table name: beta_requests
#
#  id         :bigint           not null, primary key
#  email      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class BetaRequest < ApplicationRecord
  validates :email, presence: true
end
