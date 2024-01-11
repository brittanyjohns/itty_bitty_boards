class AddTokensToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :tokens, :integer, default: 0
  end
end
