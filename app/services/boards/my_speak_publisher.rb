module Boards
  # A board that sits on a communicator's MySpeak page has to be published.
  #
  # The public page's board grid is gated on `child_boards.favorite`, but the
  # board BEHIND each card is gated on `Board#viewable_by?`, which returns
  # false for an anonymous visitor unless `published?`. Favoriting alone
  # therefore published a card that 404s on tap — and that was the DEFAULT
  # state, since Board Builder roots and AssignmentCloner clones are both born
  # unpublished.
  #
  # This closes the gap from the write side: favoriting publishes. The read
  # side has a matching filter in `Profile#communication_boards` so an
  # unpublished board can never render a card, whichever way it got there.
  class MySpeakPublisher
    def initialize(child_board)
      @child_board = child_board
    end

    def call
      return false unless child_board.favorite?
      return false unless board
      return false unless publishable_by_page_owner?
      return false if board.published?

      # `false -> true` is the safe direction for both of Board's publish
      # callbacks: `freeze_published_slug` bails because `published_was` is
      # false (so a blank slug can still be filled in on this same save), and
      # `block_marketplace_protected_unpublish` only fires on
      # `published_was && !published`.
      board.generate_unique_slug if board.slug.blank?
      board.update!(published: true)

      # Publishing a root without its set leaves every folder tile 404ing.
      # No confirmation and no `blocked_board_ids` check: publishing can't
      # break printed paper, so the cascade returns an empty blocked set for
      # `published: true`.
      Boards::PublishCascade.new(board).apply!(published: true)
      true
    end

    private

    attr_reader :child_board

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
