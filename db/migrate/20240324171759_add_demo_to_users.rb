class AddDemoToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :play_demo, :boolean, default: true
  end
end
