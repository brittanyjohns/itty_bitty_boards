class AddSourceTypeToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :source_type, :string
  end
end
