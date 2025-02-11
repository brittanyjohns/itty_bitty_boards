class TeamAccount < ApplicationRecord
  belongs_to :team
  belongs_to :account, class_name: "ChildAccount", foreign_key: "child_account_id"
  has_many :boards, through: :account

  def show_api_view
    {
      id: id,
      team: team.show_api_view,
      account: account.show_api_view,
    }
  end
end
