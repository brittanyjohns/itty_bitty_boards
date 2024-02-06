class CreateOpenSymbols < ActiveRecord::Migration[7.1]
  def change
    create_table :open_symbols do |t|
      t.string :label
      t.string :image_url
      t.string :search_string
      t.string :symbol_key
      t.string :name
      t.string :locale
      t.string :license_url
      t.string :license
      t.integer :original_os_id
      t.string :repo_key
      t.string :unsafe_result
      t.string :protected_symbol
      t.string :use_score
      t.string :relevance
      t.string :extension
      t.boolean :enabled
      t.string :author
      t.string :author_url
      t.string :source_url
      t.string :details_url
      t.string :hc

      t.timestamps
    end
  end
end
