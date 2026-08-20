# `pdf_keys` was the wrong key to select a listing's download files by.
#
# An ActiveStorage key is versioned per generation run (see
# BoardPrintable#versioned_storage_key_for), so every "Regenerate" writes new
# keys and would silently empty a per-listing allowlist — the listing would
# quietly fall back to shipping every PDF. The VARIANT ("color", "low_ink",
# "trim_ready", "full") survives a regenerate, which is what an allowlist has to
# do to mean anything.
class RenamePdfKeysOnBoardPrintableListings < ActiveRecord::Migration[8.0]
  def change
    rename_column :board_printable_listings, :pdf_keys, :pdf_variants
  end
end
