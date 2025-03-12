class CreateProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :profiles do |t|
      t.references :profileable, polymorphic: true, null: false
      t.string :username
      t.string :slug
      t.text :bio
      t.string :intro
      t.jsonb :settings, default: {}

      t.timestamps
    end
    add_index :profiles, :slug, unique: true

    ChildAccount.all.each do |child_account|
      child_account.create_profile!
    end
  end
end
