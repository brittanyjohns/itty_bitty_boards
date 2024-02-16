class AddAuthTokenToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :authentication_token, :string
    User.find_each.map(&:regenerate_authentication_token)
    add_index :users, :authentication_token, unique: true
  end
end
