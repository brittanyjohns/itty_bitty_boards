class AddPromoCodeToEvents < ActiveRecord::Migration[7.1]
  def up
    add_column :events, :promo_code, :string if !column_exists?(:events, :promo_code)
    add_index :events, :promo_code if !index_exists?(:events, :promo_code)
    add_column :events, :promo_code_details, :string if !column_exists?(:events, :promo_code_details)
    add_column :contest_entries, :winner, :boolean, default: false if !column_exists?(:contest_entries, :winner)
    add_index :contest_entries, :winner if !index_exists?(:contest_entries, :winner)
    Event.reset_column_information
    Event.find_each do |event|
      event.update(promo_code: event.slug.parameterize)
    end
  end

  def down
    remove_index :events, :promo_code if index_exists?(:events, :promo_code)
    remove_column :events, :promo_code if column_exists?(:events, :promo_code)
    remove_column :events, :promo_code_details if column_exists?(:events, :promo_code_details)
    remove_index :contest_entries, :winner if index_exists?(:contest_entries, :winner)
    remove_column :contest_entries, :winner if column_exists?(:contest_entries, :winner)
  end
end
