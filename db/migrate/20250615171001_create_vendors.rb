class CreateVendors < ActiveRecord::Migration[7.1]
  def change
    create_table :vendors do |t|
      t.references :user, foreign_key: true, null: true
      t.string :business_name
      t.string :business_email
      t.string :website
      t.string :location
      t.string :category
      t.boolean :verified, default: false
      t.text :description
      t.jsonb :configuration, default: {}

      t.timestamps
    end
  end
end
