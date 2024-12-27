class AddInfoToChildAccts < ActiveRecord::Migration[7.1]
  def change
    add_column :child_accounts, :details, :jsonb
  end
end
