# One row per Etsy listing made from a BoardPrintable.
#
# Replaces the four scalar columns on `board_printables` that used to BE the
# listing (`etsy_listing_id`, `etsy_listing_url`, `etsy_error`,
# `etsy_video_pushed_at`). Those could hold exactly one listing at a time, so
# selling a printable as both a standalone and a bundle was impossible, and
# "Detach & relist" reached a second listing only by NULLING the first —
# orphaning a real draft in a real shop with nothing in Rails pointing at it.
#
# `board_printables.etsy_published_at` is deliberately NOT replaced. It is not a
# fact about a listing; it is the fact "this printable's boards have been
# printed and sold at least once", which is what marketplace protection
# defends. Keeping it makes the new protection predicate
#
#   watermark IS NOT NULL  OR  EXISTS (a listing row that reached Etsy)
#
# strictly WIDER than the old one, so a backfill that missed a row cannot
# unfreeze boards whose printed pages are already in someone's hands.
#
# The row existing BEFORE any Etsy call is also the idempotency mechanism: the
# admin allocates a `pending` row, a compare-and-set claims it exactly once, and
# the publish job works that row. See Etsy::PublishBoardPrintableListing.
class CreateBoardPrintableListings < ActiveRecord::Migration[8.0]
  def up
    create_table :board_printable_listings do |t|
      # index: false — the composite below starts with this column, so it serves
      # the EXISTS subquery marketplace protection runs per board as well as a
      # dedicated single-column index would.
      t.references :board_printable, null: false, foreign_key: true, index: false

      # NULL until Etsy hands one back. A row with no id has touched nothing
      # external and protects nothing.
      t.bigint  :etsy_listing_id
      t.string  :etsy_listing_url

      t.string  :state,   null: false, default: "pending"    # BoardPrintableListing::STATES
      t.string  :purpose, null: false, default: "standalone" # ::PURPOSES
      t.string  :label                                       # free text, optional

      # OVERRIDES ONLY. Absent/blank keys fall back to the printable's
      # `listing_copy`, so regenerating the base copy can never clobber a
      # bundle's hand-typed title.
      t.jsonb   :listing_copy, null: false, default: {}
      t.string  :topic_override

      # Allowlists over the printable's shared assets, INTERSECTED with them —
      # never a fresh selection over `files`. Empty means "all of them".
      t.jsonb   :image_variants, null: false, default: []
      t.jsonb   :pdf_keys,       null: false, default: []

      t.datetime :published_at           # the draft was created on Etsy
      t.datetime :assets_uploaded_at     # price + images + files all landed
      t.datetime :superseded_at          # detached; the listing id is KEPT
      t.datetime :video_pushed_at        # Etsy's one-video rule is per LISTING
      t.datetime :video_push_claimed_at
      t.datetime :claimed_at             # a publish job took ownership
      t.text     :error
      t.bigint   :created_by_id

      t.timestamps
    end

    add_index :board_printable_listings, [:board_printable_id, :state]
    add_foreign_key :board_printable_listings, :users, column: :created_by_id

    backfill!

    # Added AFTER the backfill so a pre-existing duplicate aborts visibly rather
    # than being silently carried forward.
    add_index :board_printable_listings, :etsy_listing_id,
              unique: true, where: "etsy_listing_id IS NOT NULL"
  end

  def down
    drop_table :board_printable_listings

    # Step 2 of the backfill is deliberately NOT reversed. Un-stamping the
    # watermark would NARROW marketplace protection, which is the one direction
    # this table is not allowed to move.
  end

  private

  # Three legacy shapes, all of which must keep protecting their boards:
  #
  #   id + timestamp     -> one `published` row
  #   id, no timestamp   -> one `published` row, plus the watermark stamped
  #   timestamp, no id   -> one `superseded` row (a printable that was relisted)
  #
  # A printable that was relisted AND republished backfills to one `published`
  # row: the earlier draft's id was NULLed by #relist! and is genuinely
  # unrecoverable. The watermark still protects it. That is the last casualty of
  # the bug this table fixes.
  #
  # The allowlist columns (`image_variants`, `pdf_variants`) are deliberately not
  # named: they default to `[]`, which means "all of them", and naming them here
  # would pin this migration to whatever they are called in a later release.
  def backfill!
    execute(<<~SQL)
      INSERT INTO board_printable_listings
        (board_printable_id, etsy_listing_id, etsy_listing_url, state, purpose,
         label, listing_copy, published_at, assets_uploaded_at, superseded_at,
         video_pushed_at, error, created_at, updated_at)
      SELECT id, etsy_listing_id, etsy_listing_url,
             CASE WHEN etsy_listing_id IS NOT NULL THEN 'published' ELSE 'superseded' END,
             'standalone',
             CASE WHEN etsy_listing_id IS NULL
                  THEN 'Detached before listing history was kept — its Etsy id was not recorded'
             END,
             '{}'::jsonb,
             etsy_published_at,
             CASE WHEN etsy_listing_id IS NOT NULL THEN COALESCE(etsy_published_at, updated_at) END,
             CASE WHEN etsy_listing_id IS NULL     THEN updated_at END,
             etsy_video_pushed_at,
             etsy_error,
             COALESCE(etsy_published_at, created_at),
             updated_at
        FROM board_printables
       WHERE etsy_listing_id IS NOT NULL OR etsy_published_at IS NOT NULL
    SQL

    # Without this, protection NARROWS on the day the scalar id is dropped: a
    # row carrying an id but no timestamp would lose its only remaining evidence
    # of having been published.
    execute(<<~SQL)
      UPDATE board_printables
         SET etsy_published_at = COALESCE(etsy_published_at, updated_at, created_at)
       WHERE etsy_listing_id IS NOT NULL AND etsy_published_at IS NULL
    SQL
  end
end
