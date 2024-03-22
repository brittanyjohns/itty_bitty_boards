class TeamPolicy < ApplicationPolicy
    class Scope
        def initialize(user, scope)
          @user  = user
          @scope = scope
        end
    
        def resolve
          if user.admin?
            scope.all
          else
            scope.joins(:team_users).where(team_users: { user_id: user.id })
          end
        end
    
        private
    
        attr_reader :user, :scope
    end
  def create?
    user.present?
  end

  def show?
    return true if user.admin?
    record == user.current_team
  end

  def add_board?
    return true if user.admin?
    record == user.current_team
  end

  def edit?
    return true if user.admin?
    record == user.current_team && team_user.can_edit?
  end

  def update?
    return true if user.admin?
    record == user.current_team && team_user.can_edit?
  end

  def team_user
    TeamUser.where(user: user, team: record).first
  end
end
