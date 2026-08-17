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
    def initialize(board)
      @board = board
      @board_id = board.is_a?(Board) ? board.id : board.to_i
    end

    def protected? = printables.any?

    # The printables whose product depends on this board.
    def printables
      @printables ||= self.class.protecting_scope([board_id]).to_a
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

      # The UNION of both columns, matching BoardPrintable#etsy_ever_published?.
      # Not `etsy_listing_id` alone — #relist! clears that so a fresh draft can
      # be created, and keying here on it would unfreeze every relisted
      # printable's boards. Not `etsy_published_at` alone either: a row with an
      # id and no timestamp used to be protected and still must be. The two
      # definitions must not be able to disagree.
      BoardPrintable
        .where("board_printables.etsy_published_at IS NOT NULL OR board_printables.etsy_listing_id IS NOT NULL")
        .where(protection_waived_at: nil)
        .merge(matching)
    end

    private

    attr_reader :board, :board_id

    def printable_summary(printable)
      {
        id: printable.id,
        etsy_listing_id: printable.etsy_listing_id,
        etsy_listing_url: printable.etsy_listing_url,
        root_board: {
          id: printable.board_id,
          name: printable.board&.name,
        },
      }
    end
  end
end
