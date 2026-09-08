module Boards
  # A board that sits on a communicator's MySpeak page has to be published.
  #
  # The public page's board grid is gated on `child_boards.favorite`, but the
  # board BEHIND each card is gated on `Board#viewable_by?`, which returns
  # false for an anonymous visitor unless `published?`. Favoriting alone
  # therefore published a card that 404s on tap — and that was the DEFAULT
  # state, since Board Builder roots and SetCloner clones are both born
  # unpublished.
  #
  # This closes the gap from the write side: favoriting publishes. The read
  # side has a matching filter in `Profile#communication_boards` so an
  # unpublished board can never render a card, whichever way it got there.
  #
  # "The board" means the whole tree a visitor can tap into, not one row. The
  # cascade therefore runs on EVERY favorite, including one whose board is
  # already published — a published root with unpublished pages is the exact
  # broken state this class exists to prevent, and it is not a state a
  # `published?` check can distinguish from a healthy one.
  class MySpeakPublisher
    def initialize(child_board)
      @child_board = child_board
    end

    def call
      return false unless child_board.favorite?
      return false unless board
      return false unless publishable_by_page_owner?

      published_root = publish_root!

      # Publishing a root without its set leaves every folder tile 404ing.
      # No confirmation and no `blocked_board_ids` check: publishing can't
      # break printed paper, so the cascade returns an empty blocked set for
      # `published: true`.
      #
      # Runs even when the root needed nothing: the pages BELOW it may still be
      # private. Re-running on a healthy tree costs one bounded walk and writes
      # nothing — `member_boards_to_change` only returns rows that differ.
      cascaded = Boards::PublishCascade.new(board).apply!(published: true)

      published_root || cascaded.positive?
    end

    private

    attr_reader :child_board

    # True when this call is what published the root. `false -> true` is the
    # safe direction for both of Board's publish callbacks:
    # `freeze_published_slug` bails because `published_was` is false (so a
    # blank slug can still be filled in on this same save), and
    # `block_marketplace_protected_unpublish` only fires on
    # `published_was && !published`.
    def publish_root!
      return false if board.published?

      board.generate_unique_slug if board.slug.blank?
      board.update!(published: true)
      true
    end

    def board
      @board ||= child_board.board
    end

    # Only publish content the page's owner owns. A communicator's dashboard
    # can hold a board owned by someone else (an SLP's shared team board), and
    # a parent's favorite tap is not consent to make that user's board
    # publicly readable at /pb/<slug>. Mirrors
    # `PublishCascade#member_boards_to_change`, which scopes members to the
    # root board's owner for exactly this reason.
    #
    # A board left unpublished here simply doesn't appear on the public page —
    # the invariant still holds, because the read side filters too.
    def publishable_by_page_owner?
      owner_id = child_board.child_account&.user_id
      owner_id.present? && board.user_id == owner_id
    end
  end
end
