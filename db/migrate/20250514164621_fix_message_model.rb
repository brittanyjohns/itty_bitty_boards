class FixMessageModel < ActiveRecord::Migration[7.1]
  def up
    add_column :messages, :sender_id, :integer unless column_exists?(:messages, :sender_id)
    add_index :messages, :sender_id unless index_exists?(:messages, :sender_id)
    add_column :messages, :recipient_id, :integer unless column_exists?(:messages, :recipient_id)
    add_index :messages, :recipient_id unless index_exists?(:messages, :recipient_id)
    add_column :messages, :sent_at, :datetime unless column_exists?(:messages, :sent_at)
    add_index :messages, :sent_at unless index_exists?(:messages, :sent_at)
    remove_column :messages, :user_id if column_exists?(:messages, :user_id)
    remove_column :messages, :user_email if column_exists?(:messages, :user_email)
    add_column :messages, :read_at, :datetime unless column_exists?(:messages, :read_at)
    add_index :messages, :read_at unless index_exists?(:messages, :read_at)
    add_column :messages, :sender_deleted_at, :datetime unless column_exists?(:messages, :sender_deleted_at)
    add_index :messages, :sender_deleted_at unless index_exists?(:messages, :sender_deleted_at)
    add_column :messages, :recipient_deleted_at, :datetime unless column_exists?(:messages, :recipient_deleted_at)
    add_index :messages, :recipient_deleted_at unless index_exists?(:messages, :recipient_deleted_at)
  end

  def down
    remove_index :messages, :sender_id if index_exists?(:messages, :sender_id)
    remove_column :messages, :sender_id if column_exists?(:messages, :sender_id)
    remove_index :messages, :recipient_id if index_exists?(:messages, :recipient_id)
    remove_column :messages, :recipient_id if column_exists?(:messages, :recipient_id)
    remove_index :messages, :sent_at if index_exists?(:messages, :sent_at)
    remove_column :messages, :sent_at if column_exists?(:messages, :sent_at)
    add_column :messages, :user_id, :integer unless column_exists?(:messages, :user_id)
    add_column :messages, :user_email, :string unless column_exists?(:messages, :user_email)
    remove_column :messages, :read_at if column_exists?(:messages, :read_at)
    remove_index :messages, :read_at if index_exists?(:messages, :read_at)
    remove_column :messages, :sender_deleted_at if column_exists?(:messages, :sender_deleted_at)
    remove_index :messages, :sender_deleted_at if index_exists?(:messages, :sender_deleted_at)
    remove_column :messages, :recipient_deleted_at if column_exists?(:messages, :recipient_deleted_at)
    remove_index :messages, :recipient_deleted_at if index_exists?(:messages, :recipient_deleted_at)
  end
end
