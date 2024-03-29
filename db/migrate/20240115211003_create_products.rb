class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products do |t|
      t.string :name
      t.decimal :price
      t.boolean :active
      t.references :product_category, null: false, foreign_key: true
      t.text :description
      t.integer :coin_value

      t.timestamps
    end
  end
end
