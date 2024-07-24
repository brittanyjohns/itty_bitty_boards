class CreateChildBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :child_boards do |t|
      t.belongs_to :board, null: false, foreign_key: true
      t.belongs_to :child_account, null: false, foreign_key: true
      t.string :status
      t.jsonb :settings, default: {}

      t.timestamps
    end
    add_column :child_accounts, :name, :string, default: "" unless ChildAccount.column_names.include?("name")
  end
end
