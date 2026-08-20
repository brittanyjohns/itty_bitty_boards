module Boards
  # Read-only "does a marketplace listing depend on this board?" check.
  #
  # A board is protected when a BoardPrintable that reached Etsy
  # (ever published, protection not waived) was rendered from it — see
  # BoardPrintable#etsy_ever_published? for why that is a union of two columns.
  # That covers the WHOLE printed tree, not just the printable's root board:
  # every interior page carries its own QR pointing at its own `/pb/<slug>`, so
  # deleting page 4 of a twelve-page set breaks the product exactly as badly as
  # deleting the root.
  #
  # Protection is permanent by design. It defends printed paper — an Etsy
  # listing can be ended, but that doesn't recall a laminated board off a
  # fridge. BoardPrintable#waive_protection! is the one deliberate way out.
  #
  # Sibling of Boards::UsageCheck, and deliberately separate from it: usage is a
  # confirmable warning ("this is still in use, delete anyway?"), this is not.
  class MarketplaceProtection
    # "A draft was made from this printable at some point", matching
    # BoardPrintable#etsy_ever_published?. The two definitions must not be able
    # to disagree.
    #
    # Four things this deliberately does NOT do:
    #
    #   * No `superseded_at IS NULL` filter. A detached listing still protects —
    #     replacing a draft doesn't un-print the paper already carrying these
    #     boards' QR codes. Protection covers every listing ever made, not the
    #     live ones.
    #   * No `state` filter. It doesn't need one: a `pending` or `failed` row has
    #     neither an id nor a `published_at`, so allocating a listing row you
    #     never publish locks nothing. That keeps "generating a printable to look
    #     at it doesn't freeze a board" true.
    #   * The `etsy_published_at` half stays, even though every row that has it
    #     also backfilled a listing row. It is the watermark — "these boards have
    #     been printed and sold at least once" — and keeping it means this
    #     predicate is strictly WIDER than the one it replaced, so a backfill
    #     that missed a row cannot unfreeze printed paper. Widening can only
    #     over-protect; narrowing is unrecoverable.
    #   * No new index. `board_printable_listings` is indexed on
    #     `[board_printable_id, state]`, whose prefix serves this subquery.
    #
    # The legacy `etsy_listing_id` clause is still here and stays until that
    # column is dropped. Every such row was backfilled into a listing row AND
    # had the watermark stamped, so it is redundant — but "redundant" and
    # "safe to remove while the column can still be written" are different
    # claims, and only one of them is checkable. It goes with the column.
    PROTECTING_SQL = <<~SQL.squish.freeze
      board_printables.etsy_published_at IS NOT NULL
      OR board_printables.etsy_listing_id IS NOT NULL
      OR EXISTS (
           SELECT 1 FROM board_printable_listings bpl
            WHERE bpl.board_printable_id = board_printables.id
              AND (bpl.etsy_listing_id IS NOT NULL OR bpl.published_at IS NOT NULL)
         )
    SQL

    def initialize(board)
      @board = board
      @board_id = board.is_a?(Board) ? board.id : board.to_i
    end

    def protected? = printables.any?

    # The printables whose product depends on this board.
    #
    # Eager-loads listings because #summary reads them per printable. The class
    # method deliberately does NOT — .protected_board_ids flat-maps over up to
    # 100 boards and has no use for them.
    def printables
      @printables ||= self.class.protecting_scope([board_id]).includes(:etsy_listings).to_a
    end

    # :root when the board is the printable's own board, :page when it is an
    # interior page of the printed tree. Only used for wording.
    def role
      return nil unless protected?

      printables.any? { |p| p.board_id == board_id } ? :root : :page
    end

    def summary
      return nil unless protected?

      {
        role: role,
        printables: printables.map { |printable| printable_summary(printable) },
      }
    end

    # One query for many boards. Used wherever a cascade or a list would
    # otherwise run this per board.
    def self.protected_board_ids(ids)
      ids = Array(ids).map { |id| id.is_a?(Board) ? id.id : id.to_i }.uniq
      return Set.new if ids.empty?

      protecting_scope(ids).flat_map(&:protected_board_ids).to_set & ids.to_set
    end

    # The printables protecting any of `ids`.
    #
    # `board_ids` is a jsonb array of INTEGERS (Boards::Printables::Generate
    # writes `collected[:boards].map(&:id)`), so `?|` — which compares text
    # keys — would never match; containment against a json array of the same
    # integers is what works, and it's what the GIN index on board_ids serves.
    # The `board_id IN (...)` half is belt-and-braces for a printable that
    # failed before board_ids was written.
    #
    # `@>` means "contains ALL of", so a single condition can't ask for "any of
    # these ids" — it needs one `@>` per id, OR'd. Composed with ActiveRecord's
    # #or rather than by interpolating the ORs into one SQL string: the
    # interpolated version was safe (the fragment is a fixed literal repeated
    # `ids.size` times, and every id is bound) but it read as SQL injection to
    # Brakeman, and "trust me, the interpolation has no user input in it" is a
    # bad thing to have to re-verify. Each condition here is a literal with a
    # bind param, which is checkable at a glance.
    def self.protecting_scope(ids)
      ids = Array(ids).map { |id| id.is_a?(Board) ? id.id : id.to_i }.uniq
      return BoardPrintable.none if ids.empty?

      matching = ids.reduce(BoardPrintable.where(board_id: ids)) do |scope, id|
        scope.or(BoardPrintable.where("board_printables.board_ids @> ?", [id].to_json))
      end

      BoardPrintable
        .where(PROTECTING_SQL)
        .where(protection_waived_at: nil)
        .merge(matching)
    end

    private

    attr_reader :board, :board_id

    # `etsy_listing_id` / `etsy_listing_url` are the frontend's contract
    # (MarketplacePrintable in src/data/marketplaceProtection.ts, rendered by
    # MarketplaceProtectionModal). Both keys STAY, now reporting the printable's
    # primary listing rather than a scalar column — every printable that existed
    # before listing rows has exactly one, so the payload does not move.
    #
    # `etsy_listings` is additive. The current frontend ignores unknown keys, so
    # widening here is safe ahead of the modal learning to list them.
    def printable_summary(printable)
      listings = printable.etsy_listings.select(&:reached_etsy?)
      primary = listings.find(&:attached?) || listings.first

      {
        id: printable.id,
        etsy_listing_id: primary&.etsy_listing_id || printable.etsy_listing_id,
        etsy_listing_url: primary&.etsy_listing_url || printable.etsy_listing_url,
        etsy_listings: listings.map { |listing| listing_summary(listing) },
        root_board: {
          id: printable.board_id,
          name: printable.board&.name,
        },
      }
    end

    def listing_summary(listing)
      {
        id: listing.id,
        etsy_listing_id: listing.etsy_listing_id,
        etsy_listing_url: listing.etsy_listing_url,
        purpose: listing.purpose,
        label: listing.label,
        superseded: listing.superseded?,
      }
    end
  end
end
