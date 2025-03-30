class CreateContestEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :contest_entries do |t|
      t.string :name
      t.string :email
      t.jsonb :data, default: {}
      t.references :event, null: false, foreign_key: true

      t.timestamps
    end
  end
end
