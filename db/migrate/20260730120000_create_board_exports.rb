class CreateBoardExports < ActiveRecord::Migration[8.0]
  def change
    create_table :board_exports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :exportable, polymorphic: true, null: false
      t.string :status, null: false, default: "queued"
      t.string :file_format, null: false, default: "obz"
      t.text :error_message
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :board_exports, [:user_id, :created_at]
  end
end
