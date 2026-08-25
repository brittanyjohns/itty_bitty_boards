# Bulk library dedupe, modelled on AdminBoardBuild: a scanned PLAN that writes
# nothing, reviewed, then applied by a Sidekiq fan-out.
#
# `image_merges` is the ledger. `images` has no `deleted_at` (adding one would
# touch every scope in the model), so a snapshot of the destroyed row is what
# makes a bad merge diagnosable and hand-reversible after the fact.
class CreateImageMergeBatches < ActiveRecord::Migration[8.0]
  def change
    create_table :image_merge_batches do |t|
      t.string :status, null: false, default: "planned"
      t.jsonb :plan, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.jsonb :filters, null: false, default: {}
      t.bigint :created_by_id
      t.text :error_message
      t.timestamps
    end
    add_index :image_merge_batches, :status
    add_index :image_merge_batches, :created_by_id

    create_table :image_merges do |t|
      t.references :image_merge_batch, null: false, foreign_key: true
      t.integer :group_index, null: false
      t.string :status, null: false, default: "merged"
      t.bigint :survivor_id
      t.bigint :merged_image_id
      t.string :label
      t.jsonb :merged_attributes, null: false, default: {}
      t.bigint :doc_ids, array: true, null: false, default: []
      t.bigint :board_image_ids, array: true, null: false, default: []
      t.bigint :user_doc_ids, array: true, null: false, default: []
      t.bigint :reparented_board_ids, array: true, null: false, default: []
      t.text :skip_reason
      t.timestamps
    end
    add_index :image_merges, :survivor_id
    add_index :image_merges, :merged_image_id
    # One ledger row per group per batch — the idempotency key that makes a
    # replayed ImageMergeJob a no-op rather than a second merge.
    add_index :image_merges, %i[image_merge_batch_id group_index], unique: true,
              name: "index_image_merges_on_batch_and_group"
  end
end
