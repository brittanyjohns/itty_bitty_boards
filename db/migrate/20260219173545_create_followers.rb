class CreateFollowers < ActiveRecord::Migration[7.1]
  def change
    create_table :page_follows do |t|
      t.bigint :follower_user_id, null: false
      t.bigint :followed_page_id, null: false
      t.timestamps
    end

    # Prevent duplicates
    add_index :page_follows, [:follower_user_id, :followed_page_id], unique: true

    # Helpful for lookups
    add_index :page_follows, :followed_page_id
    add_index :page_follows, :follower_user_id

    # Foreign keys
    add_foreign_key :page_follows, :users, column: :follower_user_id
    add_foreign_key :page_follows, :profiles, column: :followed_page_id
  end
end
