# Safety net for the SLP→family hand-off (B6 — issue #162).
#
# When an SLP is removed from a child's team, the boards she shared with
# that team are snapshot-copied into the family's ownership so the
# communicator keeps working. The SLP keeps her originals; the family
# gets frozen copies attached as TeamBoards owned by the family.
class BoardSnapshotService
  Result = Struct.new(:snapshotted_count, :skipped_count, keyword_init: true)

  def self.snapshot_for_removed_member(team:, removed_user:)
    new(team: team, removed_user: removed_user).snapshot!
  end

  def initialize(team:, removed_user:)
    @team = team
    @removed_user = removed_user
  end

  def snapshot!
    return Result.new(snapshotted_count: 0, skipped_count: 0) if @team.nil? || @removed_user.nil?

    snapshotted = 0
    skipped = 0

    family_owner = team_family_owner
    return Result.new(snapshotted_count: 0, skipped_count: 0) unless family_owner
    return Result.new(snapshotted_count: 0, skipped_count: 0) if family_owner == @removed_user

    shared_boards_added_by_removed_user.each do |team_board|
      original = team_board.board
      next if original.nil?

      # Already-snapshotted check: avoid re-cloning if a snapshot copy
      # for this team + original exists.
      already = @team.team_boards.joins(:board)
                     .where(boards: { user_id: family_owner.id, parent_id: original.id, parent_type: "Board" })
                     .exists?
      if already
        skipped += 1
        next
      end

      cloned = original.clone_with_images(family_owner.id, original.name)
      if cloned.nil? || !cloned.persisted?
        skipped += 1
        next
      end
      cloned.update(parent_id: original.id, parent_type: "Board") if cloned.has_attribute?(:parent_id)

      @team.team_boards.create!(board: cloned, created_by_id: family_owner.id)
      repoint_dashboards!(original: original, cloned: cloned, family_owner: family_owner)
      snapshotted += 1
    rescue => e
      Rails.logger.error "[BoardSnapshotService] failed to snapshot board #{team_board.board_id} for team #{@team.id}: #{e.message}"
      skipped += 1
    end

    Rails.logger.info "[BoardSnapshotService] team=#{@team.id} removed_user=#{@removed_user.id} snapshotted=#{snapshotted} skipped=#{skipped}"
    Result.new(snapshotted_count: snapshotted, skipped_count: skipped)
  end

  private

  # The "family owner" is the team's communicator account's current
  # owner (parent after claim; SLP before). If multiple accounts are on
  # the team, take the first — this is a small-N relationship.
  # A communicator's dashboard tile points at the board ROW, and assignment
  # attaches rather than copies — so a family dashboard can be holding the
  # departing SLP's board directly. `User has_many :boards, dependent: :destroy`
  # means that tile dies the day the SLP deletes their account, and nothing else
  # re-points it: the snapshot above lands in the team library under a NEW board
  # id, disconnected from the dashboard.
  #
  # Scoped to communicators owned by this team's family owner. A different
  # family's dashboard is not ours to redirect, and the SLP's own accounts keep
  # pointing at the board they still own.
  def repoint_dashboards!(original:, cloned:, family_owner:)
    ChildBoard.where(board_id: original.id)
              .where(child_account_id: ChildAccount.where(user_id: family_owner.id).select(:id))
              .find_each do |child_board|
      # The family may already hold the snapshot on this dashboard; the unique
      # index on (board_id, child_account_id) would refuse the update, and the
      # tile already works, so drop the now-duplicate row instead.
      if ChildBoard.exists?(board_id: cloned.id, child_account_id: child_board.child_account_id)
        child_board.destroy
      else
        child_board.update_columns(board_id: cloned.id, original_board_id: original.id)
        # `update_columns` skips callbacks by design here — `publish_for_myspeak`
        # keys on the favorite TRANSITION and would not fire anyway, and
        # `recalculate_boards_in_use` only runs on create/destroy. Both effects
        # have to be asked for explicitly.
        Boards::MySpeakPublisher.new(child_board.reload).call if child_board.favorite?
      end
    end

    [original, cloned].each(&:recalculate_in_use!)
  rescue => e
    # Same posture as TeamUser#snapshot_shared_boards_to_family: never block the
    # membership removal over this.
    Rails.logger.error "[BoardSnapshotService] failed to re-point dashboards from board #{original.id} to #{cloned.id}: #{e.message}"
  end

  def team_family_owner
    account = @team.accounts.first
    account&.owner
  end

  def shared_boards_added_by_removed_user
    @team.team_boards.where(created_by_id: @removed_user.id).includes(:board)
  end
end
