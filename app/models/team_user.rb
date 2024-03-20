class TeamUser < ApplicationRecord
  belongs_to :user
  belongs_to :team

  def email
    user&.email
  end

  def name
    user&.name
  end
end
