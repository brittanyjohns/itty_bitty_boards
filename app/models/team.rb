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

  def primary_supporter
    team_users.find_by(role: "admin")&.user
  end

  def professionals
    team_users.where(role: "professional").includes(:user).map(&:user)
  end

  def all_supporters
    team_users.where(role: ["admin", "supporter", "member"]).includes(:user).map(&:user)
  end

  def supporters
    team_users.where(role: ["supporter", "member", "restricted"]).includes(:user)
  end

  def add_member!(user, role = "supporter")
    return nil if user.nil?
    if user && !users.include?(user)
      team_user = team_users.new(user: user, role: role)
      Rails.logger.debug "Adding user #{user.id} to team #{id} with role #{role}"
      team_user.save
    else
      team_user = team_users.find_by(user_id: user.id)
      Rails.logger.debug "Team user found: #{team_user.id} with role #{team_user.role}"
      unless team_user
        team_user = team_users.new(user: user, role: role)
        team_user.save
      end
      if role != team_user.role
        team_user.role = role
        Rails.logger.debug "Updating user #{user.id} role to #{role} in team #{id}"
        team_user.save
      end
    end
    unless team_user.persisted?
      Rails.logger.error "Could not add user #{user.id} to team #{id}: #{team_user.errors.full_messages.join(", ")}"
    end
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

  def add_board!(board, user_id)
    team_board = nil
    if board && !boards.include?(board)
      team_board = team_boards.new(board: board, created_by_id: user_id)
      team_board.save
    else
      team_board = team_boards.find_by(board: board, created_by_id: user_id)
    end
    team_board
  end

  def remove_board!(board)
    team_board = team_boards.find_by(board: board)
    team_board.destroy if team_board
  end

  def index_api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      created_by_id: created_by_id,
      created_by_name: created_by&.name,
      created_by_email: created_by&.email,
      members: team_users.includes(:user).map { |tu|
        { id: tu.id, name: tu.user.name, email: tu.user.email,
          role: tu.role, plan_type: tu.user.plan_type }
      },
      accounts: accounts.includes(:user).map { |a| { id: a.id, name: a.name, created_by_id: a.user_id, created_by_name: a.user&.name, created_by_email: a.user&.email, avatar_url: a.avatar_url } },

      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      updated_at: updated_at.strftime("%Y-%m-%d %H:%M:%S"),
    }
  end

  def show_api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      can_edit: viewing_user&.can_add_boards_to_account?(account_ids),
      can_invite: viewing_user && viewing_user.id == created_by_id,
      is_owner: viewing_user && viewing_user.id == created_by_id,
      created_by_id: created_by_id,
      created_by_name: created_by&.name,
      created_by_email: created_by&.email,
      accounts: accounts.includes(:user).map { |a| { id: a.id, name: a.name, created_by_id: a.user_id, created_by_name: a.user&.name, created_by_email: a.user&.email, avatar_url: a.avatar_url } },
      members: team_users.includes(:user).map { |tu|
        { id: tu.id, name: tu.user.name, email: tu.user.email,
          role: tu.role, plan_type: tu.user.plan_type }
      },
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
