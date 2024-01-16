class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.decimal :subtotal
      t.decimal :tax
      t.decimal :shipping
      t.decimal :total
      t.integer :status, default: 0
      t.references :user, null: false, foreign_key: true
      t.integer :total_coin_value

      t.timestamps
    end
  end
end
