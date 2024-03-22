class Team < ApplicationRecord
    has_many :team_users, dependent: :destroy
    has_many :users, through: :team_users
    has_many :team_boards, dependent: :destroy
    has_many :boards, through: :team_boards

    belongs_to :created_by, class_name: 'User', foreign_key: 'created_by'

    after_create :create_first_user

    def create_first_user
        user = created_by
        puts "Creating first user for team: #{user&.email}"
        TeamUser.create(team: self, user: user, role: 'admin', can_edit: true)
    end

    def add_member!(user, role='member')
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
    
end
