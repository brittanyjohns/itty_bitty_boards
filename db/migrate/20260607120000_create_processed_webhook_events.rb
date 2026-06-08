class CreateProcessedWebhookEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :processed_webhook_events do |t|
      t.string :provider, null: false       # "revenuecat" (stripe later)
      t.string :event_id, null: false       # provider's event id (UUID)
      t.string :event_type                  # INITIAL_PURCHASE, RENEWAL, ...
      t.bigint :user_id                     # resolved app_user_id, nullable
      t.string :environment                 # SANDBOX | PRODUCTION
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at

      t.timestamps
    end

    # Idempotency guarantee: a (provider, event_id) is processed at most once.
    add_index :processed_webhook_events, %i[provider event_id], unique: true
    add_index :processed_webhook_events, :user_id
  end
end
