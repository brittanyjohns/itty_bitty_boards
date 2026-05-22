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
    return true if record.predefined?
    user.team_boards.joins(:board).where(board_id: record.id).any?
  end

  def edit?
    return true if user.admin?
    return true if record.user == user
    user.current_team_boards.include?(record)
  end

  def update?
    return true if user.admin?
    return false unless record.user == user || user.current_team_boards.include?(record)
    # Free users over their board limit can edit only their one designated
    # board. Team boards (owned by someone else) are not plan-gated here.
    user.board_editable?(record)
  end

  def current_user_teams
    user.teams
  end
end
