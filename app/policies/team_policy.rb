class TeamPolicy < ApplicationPolicy
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      return [] unless user
      scope.joins(:team_users).where(team_users: { user_id: user.id })
    end

    private

    attr_reader :user, :scope
  end

  def create?
    user.present?
  end

  def show?
    return true if user.admin?
    on_the_team?
  end

  def add_board?
    return true if user.admin?
    on_the_team?
  end

  def edit?
    return true if user.admin?
    can_edit?
  end

  def update?
    return true if user.admin?
    can_edit?
  end

  def team_user
    TeamUser.where(user: user, team: record).first
  end

  def remove_team_user?
    return true if user.admin?
    return true if team_user && created_the_team?
    false
  end

  def destroy?
    return true if user.admin?
    return true if created_the_team?
    false
  end

  def can_edit?
    on_the_team? && team_user.can_edit?
  end

  def created_the_team?
    record.created_by == user
  end

  def on_the_team?
    team_user && user.current_team == record
  end
end
