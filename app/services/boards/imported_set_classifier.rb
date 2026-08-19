module Boards
  # Settles `sub_board` across an imported board set so the set reads as ONE
  # board everywhere a board is listed.
  #
  # An import can't get this right on its own: `ObzImporter` writes the tile
  # links with `update_columns` (callbacks skipped) and only once every board in
  # the package exists, so `Board#check_is_sub_board` never sees the finished
  # graph. Every page of a 30-page set stays `sub_board: false` and the whole
  # set lands in `main_boards`, in board search, and — for an admin-owned set —
  # in the public gallery. Run this once the links and the back-tile flags are
  # in place and the set collapses to the one board a human would name:
  #
  #   root  → `sub_board: false`, pinned with `settings["main_board"]` so a
  #           later save can't demote it (every page carries a way home, so the
  #           root always has inbound links)
  #   pages → `sub_board: true`, tagged "sub-board"
  #
  # Membership: pass `member_ids` when the caller knows it (a BoardGroup import
  # — every member other than the root is a page, including a page nothing links
  # to). Without it the set is walked from the root with
  # `Boards::ReachableBoardIds(skip_back_tiles: true)`, which is how a seeded
  # robust set (Core 60/84 — no BoardGroup, root identified by its own settings
  # marker) is classified. Skipping back tiles matters: a way home points at the
  # root, and following it would walk out of the set entirely.
  #
  # Idempotent — a board already on the right side is left untouched, so a
  # re-run doesn't churn `updated_at` and bust the boards-index ETag.
  class ImportedSetClassifier
    def initialize(root_board, member_ids: nil, dry_run: false)
      @root_board = root_board
      @member_ids = member_ids
      @dry_run = dry_run
    end

    # => Array<Integer> — the page board ids that were (or would be) demoted.
    def call
      return [] if root_board.blank?

      page_ids = page_board_ids
      return page_ids if dry_run

      root_board.pin_as_main_board!
      Board.where(id: page_ids).find_each(&:mark_as_sub_board!)
      page_ids
    end

    private

    attr_reader :root_board, :member_ids, :dry_run

    def page_board_ids
      ids = if member_ids.present?
          Array(member_ids)
        else
          Boards::ReachableBoardIds.new(root_board.id, skip_back_tiles: true).ids
        end

      ids.map(&:to_i).uniq - [root_board.id]
    end
  end
end
