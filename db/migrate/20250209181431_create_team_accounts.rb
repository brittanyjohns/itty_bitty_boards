class CreateTeamAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :team_accounts do |t|
      t.belongs_to :team, null: false, foreign_key: true
      t.belongs_to :child_account, null: false, foreign_key: true
      t.boolean :active, default: true
      t.jsonb :settings, default: {}

      t.timestamps
    end
  end
end
