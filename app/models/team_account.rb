# == Schema Information
#
# Table name: team_accounts
#
#  id               :bigint           not null, primary key
#  team_id          :bigint           not null
#  child_account_id :bigint           not null
#  active           :boolean          default(TRUE)
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class TeamAccount < ApplicationRecord
  belongs_to :team
  belongs_to :account, class_name: "ChildAccount", foreign_key: "child_account_id"
  has_many :boards, through: :account

  before_destroy :destroy_team, if: -> { team.team_accounts.count <= 1 }

  def destroy_team
    team.destroy
  end
end
