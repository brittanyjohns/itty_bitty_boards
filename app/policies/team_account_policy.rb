class TeamAccountPolicy < ApplicationPolicy
  # Scope: team_accounts whose team the user belongs to, OR whose
  # child_account the user owns. Admins see all. Phase 0 — the controller
  # relied on this policy but it never existed, so `policy_scope(TeamAccount)`
  # raised Pundit::NotDefinedError at runtime.
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      return scope.none unless user
      return scope.all if user.admin?

      member_team_ids = TeamUser.where(user_id: user.id).select(:team_id)
      owned_account_ids = ChildAccount.where(owner_id: user.id).select(:id)

      scope.where(team_id: member_team_ids)
           .or(scope.where(child_account_id: owned_account_ids))
    end

    private

    attr_reader :user, :scope
  end

  def show?
    return true if user&.admin?
    on_users_team? || owns_account?
  end

  def update?
    show?
  end

  def destroy?
    show?
  end

  private

  def on_users_team?
    return false unless user
    record.team.team_users.where(user_id: user.id).exists?
  end

  def owns_account?
    return false unless user
    record.account&.owner_id == user.id
  end
end
