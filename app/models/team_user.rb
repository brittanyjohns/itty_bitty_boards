# == Schema Information
#
# Table name: team_users
#
#  id                     :bigint           not null, primary key
#  user_id                :bigint           not null
#  team_id                :bigint           not null
#  role                   :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  invitation_accepted_at :datetime
#  invitation_sent_at     :datetime
#  can_edit               :boolean          default(FALSE)
#
class TeamUser < ApplicationRecord
  belongs_to :user
  belongs_to :team

  before_create :set_defaults

  def set_defaults
    self.role.blank? ? self.role = "member" : self.role
  end

  def email
    user&.email
  end

  def name
    user&.display_name
  end

  def accept_invitation!
    self.invitation_accepted_at = Time.now
    self.save
  end

  def self.roles
    { "admin" => "Admin", "member" => "Member" }
  end

  def api_view
    {
      id: id,
      email: email,
      name: name,
      role: role,
      can_edit: user.can_add_boards_to_account?(team.account_ids),
      invitation_accepted_at: invitation_accepted_at,
      user_id: user_id,
      team_id: team_id,
      created_at: created_at,
    }
  end
end
