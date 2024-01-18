class AddTokenLimitToMenus < ActiveRecord::Migration[7.1]
  def change
    add_column :menus, :token_limit, :integer, default: 0
    add_column :boards, :token_limit, :integer, default: 0
  end
end
