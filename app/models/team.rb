# == Schema Information
#
# Table name: teams
#
#  id         :bigint           not null, primary key
#  name       :string
#  created_by :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Team < ApplicationRecord
  has_many :team_users, dependent: :destroy
  has_many :users, through: :team_users
  has_many :team_boards, dependent: :destroy
  has_many :boards, through: :team_boards

  belongs_to :created_by, class_name: "User", foreign_key: "created_by"

  after_create :create_first_user

  def create_first_user
    user = created_by
    puts "Creating first user for team: #{user&.email}"
    TeamUser.create(team: self, user: user, role: "admin", can_edit: true)
    user.update(current_team: self)
  end

  def add_member!(user, role = "member")
    puts "Adding member to team: #{user&.email} as a #{role}"
    if user && !users.include?(user)
      team_user = team_users.new(user: user, role: role)
      team_user.save
    else
      team_user = team_users.find_by(user: user)
      if role != team_user.role
        team_user.role = role
        team_user.save
      end
    end
    team_user
  end

  def add_board!(board)
    puts "Adding board to team: #{board&.name}"
    team_board = nil
    if board && !boards.include?(board)
      team_board = team_boards.new(board: board)
      team_board.save
    else
      team_board = team_boards.find_by(board: board)
    end
    team_board
  end

  def remove_board!(board)
    puts "Removing board from team: #{board&.name}"
    team_board = team_boards.find_by(board: board)
    team_board.destroy if team_board
  end

  def index_api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      current: id == viewing_user&.current_team_id,
      created_by: created_by.email,
    }
  end

  def show_api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      created_by: created_by&.email,
      members: team_users.map(&:api_view),
      boards: boards.map(&:api_view_with_images),
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
