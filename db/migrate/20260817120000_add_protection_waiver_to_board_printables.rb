# A board backing a published printable is protected from deletion, unpublish
# and rename (Boards::MarketplaceProtection). Protection keys on
# `etsy_listing_id` and is otherwise permanent — what it defends is printed
# paper carrying a QR, and ending an Etsy listing doesn't un-print that. The
# waiver is the one deliberate, audited way back out.
#
# The GIN index backs the `board_ids @> '[123]'` containment lookup, which is
# how a CHILD page of a printed tree is recognised as protected.
class AddProtectionWaiverToBoardPrintables < ActiveRecord::Migration[8.0]
  def change
    add_column :board_printables, :protection_waived_at, :datetime
    add_column :board_printables, :protection_waived_by_id, :bigint
    add_column :board_printables, :protection_waived_reason, :string

    add_index :board_printables, :protection_waived_by_id
    add_index :board_printables, :board_ids, using: :gin

    add_foreign_key :board_printables, :users, column: :protection_waived_by_id
  end
end
