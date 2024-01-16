class CreateOrderItems < ActiveRecord::Migration[7.1]
  def change
    create_table :order_items do |t|
      t.references :product, null: false, foreign_key: true
      t.references :order, null: false, foreign_key: true
      t.decimal :unit_price
      t.integer :quantity
      t.decimal :total_price
      t.integer :total_coin_value
      t.integer :coin_value

      t.timestamps
    end
  end
end
