class AddNoNextToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :no_next, :boolean, default: false
  end
end
