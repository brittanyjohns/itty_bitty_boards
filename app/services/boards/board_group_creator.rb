module Boards
  # Creates (or reuses) a BoardGroup for a board so its "set map" becomes
  # available, even when the board was never built via the Board Builder
  # wizard and so never got a builder: true group automatically.
  class BoardGroupCreator
    class LimitReached < StandardError; end

    def initialize(board:, user:)
      @board = board
      @user = user
    end

    def call
      existing = board.eligible_board_group
      return existing if existing

      raise LimitReached if user.at_board_group_limit?

      create_group!
    end

    private

    attr_reader :board, :user

    def create_group!
      members = Boards::LinkedBoardsFinder.new(board).call
      group = nil
      ActiveRecord::Base.transaction do
        group = BoardGroup.create!(user: user, name: board.name, builder: false, root_board_id: board.id)
        members.each { |member| group.add_board(member) }
        # BoardGroup#set_root_board (a before_create callback) derives
        # root_board_id from boards.first at creation time, when the group
        # has no members yet — it always clobbers the value above back to
        # nil. Re-assert it now that the group is populated; update! (not
        # update_column) so out-of-band validations still run.
        group.update!(root_board_id: board.id) unless group.root_board_id == board.id
      end
      # #add_board's own `boards.include?(member)` guard memoizes the
      # (initially empty) :boards association before any members are
      # attached; reload so the caller sees every board just added rather
      # than that stale, empty cache.
      group.reload
    end
  end
end
