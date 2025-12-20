class AddTempPasswordToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :temp_login_token, :string
    add_column :users, :temp_login_expires_at, :datetime
    add_column :users, :force_password_reset, :boolean, default: false
    add_index :users, :temp_login_token, unique: true
  end
end
