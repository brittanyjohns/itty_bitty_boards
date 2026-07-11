# == Schema Information
#
# Table name: team_users
#
#  id                     :bigint           not null, primary key
#  user_id                :bigint           not null
#  team_id                :bigint           not null
#  role                   :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  invitation_accepted_at :datetime
#  invitation_sent_at     :datetime
#  can_edit               :boolean          default(FALSE)
#
class TeamUser < ApplicationRecord
  # Canonical role set (issue #216). Permissions matrix lives in
  # marketing/.claude-notes/handoff-workflow.md:
  #   admin      — team owner; full curation + member management.
  #   supervisor — power collaborator (SLP). Can curate boards on the
  #                communicator (assign to the dashboard) but cannot edit
  #                the communicator object or delete the account.
  #   member     — "Support": can add boards to the team library but cannot
  #                assign them to a communicator.
  #   restricted — "Read-Only": view the team only. No library writes, no
  #                curation.
  ROLES = %w[admin supervisor member restricted].freeze

  # Roles allowed to WRITE to the team's board library (`create_board`).
  # `restricted` is read-only and excluded. `admin` is the team owner's
  # role and is only ever set server-side (never via invite).
  LIBRARY_ROLES = %w[admin supervisor member].freeze

  belongs_to :user
  belongs_to :team

  before_validation :set_defaults, on: :create
  validates :role, inclusion: { in: ROLES, message: "must be admin, supervisor, member, or restricted" }
  before_destroy :snapshot_shared_boards_to_family

  # Safety net for the SLP→family hand-off (B6 — issue #162). When this
  # membership is destroyed, copy any boards this user shared into the
  # family's ownership so the communicator never loses access.
  def snapshot_shared_boards_to_family
    BoardSnapshotService.snapshot_for_removed_member(team: team, removed_user: user)
  rescue => e
    Rails.logger.error "[TeamUser##{id}] board snapshot on destroy failed: #{e.message}"
    # Never block the membership removal — the family losing future
    # access is worse than a missed snapshot, which can be re-run.
    true
  end

  def set_defaults
    self.role.blank? ? self.role = "member" : self.role
  end

  def email
    user&.email
  end

  def name
    user&.display_name
  end

  def accept_invitation!
    self.invitation_accepted_at = Time.now
    self.save
  end

  def self.roles
    { "admin" => "Admin", "supervisor" => "Supervisor", "member" => "Support", "restricted" => "Read-Only" }
  end

  # True if this user is the owner of any child_account on the team. Used
  # by `API::TeamsController` to block removal / role-change of the owner
  # by anyone other than themselves (issue #166).
  def account_owner?
    team.account_owner?(user)
  end

  def api_view
    {
      id: id,
      email: email,
      name: name,
      role: role,
      can_edit: user.can_add_boards_to_account?(team.account_ids),
      is_account_owner: account_owner?,
      invitation_accepted_at: invitation_accepted_at,
      user_id: user_id,
      team_id: team_id,
      created_at: created_at,
      user: user.api_view,
    }
  end
end
