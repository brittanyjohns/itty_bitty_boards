# == Schema Information
#
# Table name: teams
#
#  id              :bigint           not null, primary key
#  name            :string
#  created_by_id   :integer          not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organization_id :bigint
#
class Team < ApplicationRecord
  has_many :team_users, dependent: :destroy
  has_many :users, through: :team_users
  has_many :team_boards, dependent: :destroy
  has_many :boards, through: :team_boards
  has_many :team_accounts, dependent: :destroy
  has_many :accounts, through: :team_accounts
  has_many :account_boards, through: :team_accounts, source: :boards
  belongs_to :created_by, class_name: "User", foreign_key: "created_by_id"

  # scope :with_artifacts, -> { includes(team_users: :user, team_boards: :board, team_accounts: :account) }
  scope :with_artifacts, -> { includes(:created_by, team_users: :user, team_boards: { board: :user }, team_accounts: { account: :user }) }

  def available_team_account_boards
    # team_accounts.includes(account: :boards).map(&:boards).flatten.uniq
    account_boards.where.not(id: team_boards.pluck(:board_id))
  end

  def self.cleanup_ophaned
    self.includes(:team_accounts).each do |team|
      team.destroy if team.team_accounts.empty?
    end
  end

  # Upsert a team membership: add `user` at `role`, or update an
  # existing membership's role if it differs. Raises on validation
  # failure (e.g. role outside `TeamUser::ROLES`). Returns the
  # persisted TeamUser. Returns nil only when `user` is nil.
  #
  # Named `upsert_member!` rather than `add_member!` because the
  # silent-role-overwrite behavior was a footgun under the old name
  # (issue #226).
  def upsert_member!(user, role = "member")
    return nil if user.nil?
    team_user = team_users.find_or_initialize_by(user_id: user.id)
    team_user.role = role
    team_user.save!
    team_user
  end

  def add_communicator!(account)
    team_account = nil
    if account && !accounts.include?(account)
      team_account = team_accounts.new(account: account)
      team_account.save
    else
      team_account = team_accounts.find_by(account: account)
    end
    team_account
  end

  # Share `board` with this team. Idempotent, and never returns nil for a real
  # board — the old implementation looked an existing row up by
  # `(board, created_by_id)`, so re-sharing a board somebody ELSE had already
  # shared returned nil and the caller's `.save` raised NoMethodError.
  #
  # Two things it deliberately does not do on an existing row:
  #   * overwrite `created_by_id` — attribution belongs to the first sharer,
  #     and `BoardSnapshotService` keys the SLP-leaves snapshot on it;
  #   * touch `allow_edit` — re-sharing must not silently grant or revoke.
  def add_board!(board, user_id)
    return nil unless board
    team_boards.create!(board: board, created_by_id: user_id)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    team_boards.find_by(board_id: board.id)
  end

  # `destroy_all` rather than `find_by(...).destroy`: this is the REVOCATION
  # path, and on data predating the unique index a board could sit on a team
  # twice — removing one row and leaving the other is a revoke that does not
  # revoke.
  def remove_board!(board)
    return nil unless board
    team_boards.where(board_id: board.id).destroy_all
  end

  # User ids of the owners of any child_account on this team. These users
  # are "owner-pinned" — they cannot be removed or have their role changed
  # by anyone other than themselves (or a system admin). The frontend reads
  # this to hide destructive controls on the owner row.
  def account_owner_ids
    accounts.pluck(:owner_id).compact.uniq
  end

  def account_owner?(user)
    return false unless user
    account_owner_ids.include?(user.id)
  end

  # The viewing user's team-membership role (admin/supervisor/member/
  # restricted), or nil if they aren't a member. Exposed so the frontend
  # doesn't have to derive role by email-matching the members array.
  def role_for(user)
    return nil unless user
    team_users.detect { |tu| tu.user_id == user.id }&.role
  end

  # `User` is soft-deleted (`default_scope { where(deleted_at: nil) }`), so a
  # team_users row can outlive the user it points at and preload `user` as nil.
  # INNER JOIN so those rows drop out rather than blowing up on `tu.user.name`.
  # `invitation_accepted_at` is here because "invited" and "joined" are
  # otherwise indistinguishable to the owner. `TeamsController#invite` calls
  # `upsert_member!` unconditionally, so an invitee is a full member row from
  # the moment the invite POSTs — before they have opened the email, and for a
  # brand-new address before they have an account at all. Without this field the
  # roster counts four people who may never arrive as members (issue #914).
  #
  # It is deliberately NOT a separate `pending_invites` array (the shape #493
  # proposed): those team_users are already in this list, so a parallel array
  # would render every pending person twice.
  def member_views(owner_ids)
    team_users.joins(:user).includes(:user).map { |tu|
      { id: tu.id, user_id: tu.user_id, name: tu.user.name, email: tu.user.email,
        role: tu.role, plan_type: tu.user.plan_type,
        is_account_owner: owner_ids.include?(tu.user_id),
        invitation_accepted_at: tu.invitation_accepted_at }
    }
  end

  def index_api_view(viewing_user = nil)
    owner_ids = account_owner_ids
    {
      id: id,
      name: name,
      created_by_id: created_by_id,
      created_by_name: created_by&.name,
      created_by_email: created_by&.email,
      current_user_role: role_for(viewing_user),
      account_owner_ids: owner_ids,
      members: member_views(owner_ids),
      accounts: accounts.includes(:user).map { |a| { id: a.id, name: a.name, owner_id: a.owner_id, created_by_id: a.user_id, created_by_name: a.user&.name, created_by_email: a.user&.email, avatar_url: a.avatar_url } },

      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      updated_at: updated_at.strftime("%Y-%m-%d %H:%M:%S"),
    }
  end

  def show_api_view(viewing_user = nil)
    owner_ids = account_owner_ids
    {
      id: id,
      name: name,
      can_edit: viewing_user&.can_add_boards_to_account?(account_ids),
      can_invite: viewing_user && viewing_user.id == created_by_id,
      is_owner: viewing_user && viewing_user.id == created_by_id,
      current_user_role: role_for(viewing_user),
      created_by_id: created_by_id,
      created_by_name: created_by&.name,
      created_by_email: created_by&.email,
      account_owner_ids: owner_ids,
      accounts: accounts.includes(:user).map { |a| { id: a.id, name: a.name, owner_id: a.owner_id, created_by_id: a.user_id, created_by_name: a.user&.name, created_by_email: a.user&.email, avatar_url: a.avatar_url } },
      members: member_views(owner_ids),
      boards: team_boards.includes(board: :user).map { |tb| { id: tb.board_id, name: tb.board.name, board_type: tb.board.board_type, display_image_url: tb.board.display_image_url, added_by_id: tb.created_by_id, board_owner_name: tb.board.user&.display_name, board_owner_id: tb.board.user_id } },
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      updated_at: updated_at.strftime("%Y-%m-%d %H:%M:%S"),
    }
  end

  def api_view
    {
      id: id,
      name: name,
      created_by: created_by&.email,
    }
  end
end
