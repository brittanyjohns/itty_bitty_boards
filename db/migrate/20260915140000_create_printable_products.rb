# A non-board product sold as a printable — first AAC device tags (#957). Holds
# the product's own design artwork and buyer files as NAMED attachments, and is
# a SceneComposition owner so its artwork can be warped into scene mockups.
class CreatePrintableProducts < ActiveRecord::Migration[8.0]
  def change
    create_table :printable_products do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :category, null: false, default: "device_tag"
      t.text :description
      t.string :size_label
      t.string :status, null: false, default: "draft"
      t.jsonb :canva_templates, null: false, default: []

      t.timestamps
    end

    add_index :printable_products, :slug, unique: true
    add_index :printable_products, :status
  end
end
