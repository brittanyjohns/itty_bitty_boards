class CreateCreditTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table :credit_transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :amount, null: false
      t.string :kind, null: false
      t.string :source, null: false
      t.string :feature_key
      t.string :stripe_event_id
      t.string :stripe_price_id
      t.datetime :expires_at
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :credit_transactions, :stripe_event_id, unique: true, where: "stripe_event_id IS NOT NULL"
    add_index :credit_transactions, [:user_id, :created_at]
    add_index :credit_transactions, [:user_id, :kind]
    add_index :credit_transactions, :expires_at, where: "expires_at IS NOT NULL"
  end
end
