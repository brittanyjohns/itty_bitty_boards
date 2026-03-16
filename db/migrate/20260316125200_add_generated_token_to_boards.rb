class AddGeneratedTokenToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :generated_token, :string
    add_index :boards, :generated_token, unique: true
    add_column :boards, :generated_token_expires_at, :datetime
    add_index :boards, :generated_token_expires_at
    change_column_null :boards, :user_id, true
  end
end
