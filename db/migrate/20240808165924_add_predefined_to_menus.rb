class AddPredefinedToMenus < ActiveRecord::Migration[7.1]
  def change
    add_column :menus, :predefined, :boolean, default: false
  end
end
