class CreateDocs < ActiveRecord::Migration[7.1]
  def change
    create_table :docs do |t|
      t.references :documentable, polymorphic: true, null: false
      t.text :raw_text
      t.text :processed_text
      t.boolean :current, default: false
      t.timestamps
    end
  end
end
