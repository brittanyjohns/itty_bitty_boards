# frozen_string_literal: true

require "rails_helper"

# `User#board_editable?` opens with `return true if board.user_id != id` — it
# measures "is this board of MINE locked", so asking it about somebody else's
# board answers true unconditionally. Every write gate that a non-owner can
# reach therefore has to measure the OWNER's plan instead, or a read-only board
# becomes writable through anyone whose own plan is fine.
RSpec.describe Board, "#owner_plan_allows_edit?" do
  # A Free owner one board past the editable-slot floor — below the floor
  # nothing locks at all. Ordered oldest-first, so `boards.first` is the one
  # recency drops out of the editable set, and `boards.last` is safely inside
  # it. Mirrors spec/models/board_read_only_spec.rb's fixture.
  def locked_free_owner
    owner = create(:free_user)
    boards = Array.new(User::EDITABLE_BOARD_FLOOR + 1) { create(:board, user: owner) }
      .each_with_index { |b, i| b.update_column(:updated_at, (20 - i).days.ago) }
    [User.find(owner.id), boards.first, boards.last]
  end

  it "is false for a board whose owner is over their plan's limit" do
    _owner, locked_board, _editable = locked_free_owner

    expect(Board.find(locked_board.id).owner_plan_allows_edit?).to be false
  end

  it "is true for a board still inside the owner's editable slots" do
    _owner, _locked, editable = locked_free_owner

    expect(Board.find(editable.id).owner_plan_allows_edit?).to be true
  end

  it "is true for a board the owner explicitly designated" do
    owner, locked_board, _editable = locked_free_owner
    owner.update!(editable_board_id: locked_board.id)

    expect(Board.find(locked_board.id).owner_plan_allows_edit?).to be true
  end

  # The whole point: the answer must not move when a different, better-funded
  # person is the one asking. The method takes no viewer argument at all —
  # that is the design, not an omission.
  it "does not consult the person asking" do
    _owner, locked_board, _editable = locked_free_owner
    create(:user, plan_type: "pro")

    expect(Board.find(locked_board.id).owner_plan_allows_edit?).to be false
  end

  it "is true for a paid owner" do
    owner = create(:user, plan_type: "pro")
    board = create(:board, user: owner)

    expect(Board.find(board.id).owner_plan_allows_edit?).to be true
  end

  it "is true for a board with no owner — there is no plan to measure" do
    board = create(:board, user: create(:user))
    board.update_columns(user_id: nil)

    expect(Board.find(board.id).owner_plan_allows_edit?).to be true
  end

  # Regression: reading the owner through the `user` association returns the
  # instance the board was BUILT with (`create(:board, user: owner)` assigns
  # it), whose plan attributes and memoized `countable_board_count` predate
  # anything changed since. This is a security gate and must read current state.
  it "reads current plan state, not the instance the board was built with" do
    owner = create(:user, plan_type: "pro")
    boards = Array.new(User::EDITABLE_BOARD_FLOOR + 1) { create(:board, user: owner) }
      .each_with_index { |b, i| b.update_column(:updated_at, (20 - i).days.ago) }
    subject_board = boards.first

    # `subject_board.user` is the in-memory Pro `owner`; the downgrade lands
    # in the database only.
    User.where(id: owner.id).update_all(plan_type: "free", plan_status: nil)

    expect(subject_board.owner_plan_allows_edit?).to be false
  end
end
