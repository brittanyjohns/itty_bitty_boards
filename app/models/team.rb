class Team < ApplicationRecord
    has_many :team_users, dependent: :destroy
    has_many :users, through: :team_users

    belongs_to :created_by, class_name: 'User', foreign_key: 'created_by'

    after_create :create_first_user

    def create_first_user
        user = created_by
        puts "Creating first user for team: #{user&.email}"
        TeamUser.create(team: self, user: user, role: 'admin')
    end

    def add_member!(user)
        puts "Adding member to team: #{user&.email}"
        if user && !users.include?(user)
            team_user = team_users.new(user: user, role: 'member')
            team_user.save
        else
            team_user = team_users.find_by(user: user)
        end
        team_user
    end
    
end
