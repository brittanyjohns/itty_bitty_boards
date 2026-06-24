class AddLegacySlugToProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :profiles, :legacy_slug, :string
    add_column :profiles, :slug_type, :string, default: "legacy", null: false
    # Conditional unique index — many rows will have a NULL legacy_slug and
    # NULLs are excluded so they don't collide with each other.
    add_index :profiles, :legacy_slug, unique: true, where: "legacy_slug IS NOT NULL"
  end
end
