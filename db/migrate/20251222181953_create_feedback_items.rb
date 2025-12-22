class CreateFeedbackItems < ActiveRecord::Migration[7.1]
  def change
    create_table :feedback_items do |t|
      t.references :user, null: false, foreign_key: true

      t.string :feedback_type, null: false # bug, feature, question, praise
      t.string :role, null: false          # parent, slp, teacher, vendor, partner, other

      t.string :subject
      t.text :message, null: false

      t.string :page_url
      t.string :app_version
      t.string :platform
      t.string :device

      t.boolean :allow_contact, default: true, null: false

      t.timestamps
    end

    add_index :feedback_items, :created_at
    add_index :feedback_items, :feedback_type
    add_index :feedback_items, :role
  end
end
