class AddSkuToProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :profiles, :sku, :string
    add_index :profiles, :sku, unique: true
  end
end
