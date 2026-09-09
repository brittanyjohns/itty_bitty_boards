# The read-only board lock, in one place.
#
# Boards over a downgraded user's plan limit stay fully usable — view, tap,
# audio — but are not editable. This is the gate that refuses the writes, and
# it is HTTP 403: 402 is reserved for credit exhaustion.
#
# Two things it gets right that the two hand-rolled copies did not:
#
#   * **The plan measured is the BOARD OWNER's.** `User#board_editable?` opens
#     with `return true if board.user_id != id`, so measuring the CALLER makes
#     the lock evaporate for anyone who does not own the board. `Board#owner_plan_allows_edit?`
#     is the single definition.
#   * **A non-owner's refusal carries no `board_limit` and no
#     `editable_board_id`.** Those are the owner's plan tier and the id of
#     another of their boards — their private data, and useless to a caller who
#     cannot act on them anyway. They get `board_locked_owner_plan` instead, so
#     a client can render "the owner has to fix this" rather than an Upgrade
#     button that would charge the wrong person.
module BoardPlanLock
  extend ActiveSupport::Concern

  private

  # Renders and returns true when `board` is locked for `user`; returns false
  # when the write may proceed. Callers use it as a `before_action` body:
  #
  #   return if refuse_when_board_locked!(@board, acting_user)
  #
  # `user` is passed explicitly because the two callers resolve it differently
  # — #add_image reaches the boards controller on a communicator token, where
  # `current_user` is nil and the plan belongs to the adult who owns the
  # account (`acting_user`).
  def refuse_when_board_locked!(board, user)
    return false if board.nil?

    # No resolvable user means there is no plan to measure against, and the
    # body below would be full of nils. Checked before the lock so the answer
    # does not depend on whether this particular board happens to be locked.
    if user.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return true
    end

    return false if board.owner_plan_allows_edit?

    if board.user_id == user.id || user.admin?
      render json: {
        error: "board_locked",
        message: "This board is read-only on your current plan. Upgrade, or make it your editable board, to make changes.",
        board_limit: user.board_limit,
        editable_board_id: user.effective_editable_board_id,
      }, status: :forbidden
    else
      render json: {
        error: "board_locked_owner_plan",
        message: "This board is read-only because the person who owns it is over their plan's board limit. They can make it editable again from their account.",
      }, status: :forbidden
    end

    true
  end
end
