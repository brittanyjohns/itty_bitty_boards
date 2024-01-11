class UserDoc < ApplicationRecord
  belongs_to :user
  belongs_to :doc
end
