class AddPermanentSlugToProfiles < ActiveRecord::Migration[8.0]
  # The identifier a printed device tag's QR resolves through. Separate from
  # `slug` because the two have opposite requirements: `slug` is the address a
  # person sees and may need to change (a leaked link has to be revocable),
  # while the QR is stuck to a child's iPad and can never move.
  #
  # Nullable + backfilled by `rake profiles:backfill_permanent_slugs` rather
  # than filled in here, so this deploys instantly on a large table and in
  # either order. Readers fall back to `slug` while it is nil
  # (`Profile#printable_slug`).
  def change
    add_column :profiles, :permanent_slug, :string
    add_index :profiles, :permanent_slug, unique: true, where: "permanent_slug IS NOT NULL"
  end
end
