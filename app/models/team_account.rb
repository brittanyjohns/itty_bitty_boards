class TeamAccount < ApplicationRecord
  belongs_to :team
  belongs_to :account, class_name: "ChildAccount", foreign_key: "child_account_id"

  def show_api_view
    {
      id: id,
      team: team.show_api_view,
      account: account.show_api_view,
    }
  end
end
