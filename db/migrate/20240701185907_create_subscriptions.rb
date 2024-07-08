class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.string :stripe_subscription_id
      t.string :stripe_plan_id
      t.string :status
      t.datetime :expires_at
      t.integer :price_in_cents
      t.string :interval, default: "month"
      t.string :stripe_customer_id
      t.integer :interval_count, default: 1
      t.string :stripe_invoice_id
      t.string :stripe_client_reference_id
      t.string :stripe_payment_status

      t.timestamps
    end
  end
end
