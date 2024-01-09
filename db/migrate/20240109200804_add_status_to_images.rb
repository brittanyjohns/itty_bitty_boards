class AddStatusToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :status, :string
    add_column :images, :error, :string
  end
end
