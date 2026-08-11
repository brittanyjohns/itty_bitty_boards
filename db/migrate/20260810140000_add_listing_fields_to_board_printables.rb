class AddListingFieldsToBoardPrintables < ActiveRecord::Migration[8.0]
  def change
    add_column :board_printables, :listing_copy, :jsonb, default: {}, null: false
    add_column :board_printables, :etsy_listing_id, :bigint
    add_column :board_printables, :etsy_listing_url, :string
    add_column :board_printables, :etsy_published_at, :datetime
    add_column :board_printables, :etsy_error, :text

    add_index :board_printables, :etsy_listing_id
  end
end
