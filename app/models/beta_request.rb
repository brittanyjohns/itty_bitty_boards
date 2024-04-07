class BetaRequest < ApplicationRecord
  validates :email, presence: true, uniqueness: true
end
