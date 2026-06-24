class CreateProfileViews < ActiveRecord::Migration[7.1]
  def change
    create_table :profile_views do |t|
      t.references :profile, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.string :approx_location # coarse, e.g. "Austin, Texas, US"
      t.jsonb :geo, default: {}, null: false # raw coarse geo: city/region/country
      t.boolean :notified, default: false, null: false
      t.datetime :viewed_at, null: false

      t.timestamps
    end

    add_index :profile_views, [:profile_id, :viewed_at]
  end
end
