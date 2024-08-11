class AddRawToMenus < ActiveRecord::Migration[7.1]
  def change
    add_column :menus, :raw, :text
    add_column :menus, :item_list, :string, array: true, default: []
    add_column :menus, :prompt_sent, :text
    add_column :menus, :prompt_used, :text
  end
end
