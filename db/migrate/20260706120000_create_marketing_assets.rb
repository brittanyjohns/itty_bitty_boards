class CreateMarketingAssets < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_assets do |t|
      t.string :slug, null: false
      t.string :title
      t.string :kind, null: false, default: "kit"

      t.timestamps
    end

    add_index :marketing_assets, :slug, unique: true
  end
end
