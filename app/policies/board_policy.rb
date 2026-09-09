class BoardPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if user.admin?
        scope.all.user_made
      else
        scope.where(user: user).user_made
      end
    end
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

  # NOTE: there is deliberately no `edit?` / `update?` here.
  #
  # They used to grant edit via `user.current_team_boards.include?(record)` —
  # no team role, no per-board grant, and no ownership. Nothing calls Pundit's
  # `authorize` on a Board (only `policy_scope`), so they were dead; but they
  # said the opposite of the rule the controllers actually enforce, and would
  # have handed every member of every team write access to every board on it
  # the day someone wired them up.
  #
  # Board write permission lives in one place: `Board#can_edit_for` (the flag)
  # and `API::BoardsController#check_board_view_edit_permissions` (the gate).

  def current_user_teams
    user.teams
  end
end
