# A listing's CURATED Etsy gallery: an ordered allowlist of image refs
# (`legacy:on_paper`, `styled:styled_hero`, ...), at most ten — Etsy's cap.
#
# An EMPTY array means "never curated" and behaves exactly as a listing did
# before this column existed: the ten legacy slides in LISTING_IMAGE_ORDER,
# narrowed by `image_variants`. That is why there is no backfill — every
# existing row is already in the state that means "unchanged".
class AddGalleryItemsToBoardPrintableListings < ActiveRecord::Migration[8.0]
  def change
    add_column :board_printable_listings, :gallery_items, :jsonb, default: [], null: false
  end
end
