class AddFieldsToTeamUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :team_users, :invitation_accepted_at, :datetime
    add_column :team_users, :invitation_sent_at, :datetime
  end
end
