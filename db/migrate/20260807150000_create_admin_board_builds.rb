class CreateAdminBoardBuilds < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_board_builds do |t|
      # Null until the build actually writes a board.
      t.references :board, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.string :name, null: false
      t.string :topic
      t.string :voice, null: false, default: "polly:kevin"
      t.integer :columns_count, null: false
      t.integer :rows_count, null: false
      t.boolean :commercial_safe_only, null: false, default: true
      # The authored tiles. Persisted so a failed build is re-runnable without
      # re-authoring, and so `show` has something to render.
      t.jsonb :plan, null: false, default: {}
      # What the build actually resolved: coverage, labels with no art, and the
      # images it queued generation for.
      t.jsonb :art_report, null: false, default: {}
      t.text :error_message

      t.timestamps
    end

    add_index :admin_board_builds, [:status, :created_at]
  end
end
