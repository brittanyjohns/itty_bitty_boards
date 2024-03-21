class TeamBoard < ApplicationRecord
  belongs_to :board
  belongs_to :team
end
