class FixRawAndProcessedColumns < ActiveRecord::Migration[7.1]
  def change
    rename_column :docs, :raw_text, :processed
    rename_column :docs, :processed_text, :raw
  end
end
