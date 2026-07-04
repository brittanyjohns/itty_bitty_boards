class CreateDownloadLeads < ActiveRecord::Migration[7.1]
  def change
    create_table :download_leads do |t|
      t.string :email, null: false
      t.string :name
      # board_id is intentionally NOT a hard FK constraint — leads can outlive
      # the board they were captured from.
      t.bigint :board_id
      t.string :source
      t.string :mailchimp_status, default: "pending"
      t.jsonb :data, default: {}

      t.timestamps
    end

    add_index :download_leads, :email
    add_index :download_leads, :board_id
  end
end
