class AddStatusToChildAccounts < ActiveRecord::Migration[7.1]
  def up
    add_column :child_accounts, :status, :string, default: "sandbox", null: false
    add_index :child_accounts, :status

    # Backfill: is_demo:true → sandbox, is_demo:false → active.
    # is_demo column is kept for now; removed after frontend cutover (F1).
    execute <<~SQL
      UPDATE child_accounts SET status = 'sandbox' WHERE is_demo = TRUE;
      UPDATE child_accounts SET status = 'active'  WHERE is_demo = FALSE;
    SQL
  end

  def down
    remove_index :child_accounts, :status
    remove_column :child_accounts, :status
  end
end
