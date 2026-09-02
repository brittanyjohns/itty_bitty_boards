class CreateMailDeliveries < ActiveRecord::Migration[8.0]
  def change
    create_table :mail_deliveries do |t|
      t.string :status, null: false
      t.string :recipients
      t.string :from_address
      t.string :subject
      # The key a Google Workspace Email Log Search takes — the only place the
      # accepted-then-dropped case is visible.
      t.string :message_id
      t.string :mailer
      t.string :transport
      # Why a send was suppressed (staging block, e2e address).
      t.string :reason
      t.string :error_class
      t.text :error_message

      t.timestamps
    end

    add_index :mail_deliveries, [:status, :created_at]
    add_index :mail_deliveries, :created_at
    add_index :mail_deliveries, :message_id
    add_index :mail_deliveries, :recipients
  end
end
