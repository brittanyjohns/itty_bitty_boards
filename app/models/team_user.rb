class TeamUser < ApplicationRecord
  belongs_to :user
  belongs_to :team

  before_create :set_defaults

  def set_defaults
    self.role.blank? ? self.role = 'member' : self.role
  end

  def email
    user&.email
  end

  def name
    user&.name
  end

  def accept_invitation!
    self.invitation_accepted_at = Time.now
    self.save
  end

  def self.roles
    { 'admin' => 'Admin', 'member' => 'Member'}
  end
end
