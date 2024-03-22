class BoardPolicy < ApplicationPolicy
    class Scope
        def initialize(user, scope)
          @user  = user
          @scope = scope
        end
    
        def resolve
          if user.admin?
            scope.all.user_made
          else
            scope.where(user: user).user_made
          end
        end
    
        private
    
        attr_reader :user, :scope
    end
  def create?
    user.admin?
  end

  def show?
    return true if user.admin?
    return true if record.user == user
    user.team_boards.joins(:board).where(board_id: record.id).any?
  end

  def edit?
    return true if user.admin?
    return true if record.user == user
    user.current_team_boards.include?(record)
  end

  def update?
    return true if user.admin?
    return true if record.user == user
    user.current_team_boards.include?(record)
  end

  def current_user_teams
    user.teams
  end
end
