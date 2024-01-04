class Menu < ApplicationRecord
  belongs_to :user
  has_many :boards, as: :parent
end
