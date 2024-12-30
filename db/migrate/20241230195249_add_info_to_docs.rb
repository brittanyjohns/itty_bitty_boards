class AddInfoToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :data, :jsonb
    add_column :docs, :license, :jsonb
  end
end
