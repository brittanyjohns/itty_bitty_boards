# == Schema Information
#
# Table name: child_accounts
#
#  id                     :bigint           not null, primary key
#  username               :string           default(""), not null
#  name                   :string           default("")
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  last_sign_in_ip        :string
#  user_id                :bigint
#  authentication_token   :string
#  settings               :jsonb
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  passcode               :string
#  details                :jsonb
#  placeholder            :boolean          default(FALSE)
#
class ChildAccount < ApplicationRecord
  # devise :database_authenticatable, :trackable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  belongs_to :user, optional: true
  has_many :child_boards, dependent: :destroy
  has_many :boards, through: :child_boards
  has_many :images, through: :boards
  has_many :word_events, dependent: :destroy
  has_secure_token :authentication_token
  has_many :team_accounts, dependent: :destroy
  has_many :teams, through: :team_accounts
  has_many :team_users, through: :teams
  has_many :team_boards, through: :teams
  has_one :profile, as: :profileable

  include WordEventsHelper

  # validates :passcode, presence: true, on: :create
  # validates :passcode, length: { minimum: 6 }, on: :create

  validates :username, presence: true, uniqueness: true

  delegate :display_docs_for_image, to: :user

  # after_save :create_profile!, if: -> { profile.nil? }

  scope :alphabetical, -> { order(Arel.sql("LOWER(name) ASC")) }

  scope :with_artifacts, -> { includes(:profile, :child_boards, :boards, :images, :word_events, :user, teams: [:team_users]) }
  scope :with_teams, -> { includes(teams: [:team_users]) }
  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }

  def self.valid_credentials?(username, password_to_set)
    account = ChildAccount.find_by(username: username, passcode: password_to_set)
    if account
      puts "Account found: #{account.inspect}"
      account
    else
      Rails.logger.info "Invalid credentials for #{username}"
      nil
    end
  end

  def user_docs
    user.user_docs
  end

  def avatar_url
    if profile
      profile.avatar_url
    else
      ""
    end
  end

  def reset_password(new_password, new_password_confirmation)
    if new_password == new_password_confirmation
      update!(password: new_password, password_confirmation: new_password_confirmation)
    else
      raise "Passwords do not match"
    end
  end

  def self.find_by_token(token)
    find_by(authentication_token: token)
  end

  def favorite_boards
    child_boards.where(favorite: true).includes(:board).map(&:board)
  end

  def self.create_for_user(user, username, password)
    account = new(username: username, password: password, user: user, password_confirmation: password)
    account.save!
    account
  end

  def email
    settings = self.settings || {}
    settings["email"]
  end

  def send_setup_email(sending_user)
    CommunicationAccountMailer.setup_email(self, sending_user).deliver_now
  end

  def create_profile!
    return if profile.present?
    slug = username.parameterize
    if Profile.find_by(slug: slug)
      slug = "#{slug}-#{id}"
    end
    profile = Profile.create!(profileable: self, username: username, slug: slug)
    profile.set_fake_avatar
    profile.save!
  end

  def print_credentials
    puts "UserId: #{user_id} Username: #{username} Password: #{passcode}"
  end

  def can_sign_in?(user_context = nil)
    if user_context && user_context.admin?
      return true
    end

    if self.user.admin?
      return true
    end

    if user
      user.pro? ? true : user.free_trial?
    else
      if self.user.admin?
        return true
      end
      puts "No user provided"
      false
    end
  end

  def admin?
    user.admin?
  end

  def available_boards
    current_board_ids = self.child_boards.distinct.pluck(:board_id)
    current_boards = Board.where(id: current_board_ids)
    user.boards.where.not(id: current_boards.pluck(:id)).order(:name)
  end

  def available_teams_boards
    current_board_ids = self.child_boards.distinct.pluck(:board_id)
    # current_boards = Board.where(id: current_board_ids)
    # # teams.map { |t| t.boards.where.not(id: current_boards.pluck(:id)).order(:name) }.flatten
    # team_boards = teams.map { |t| t.boards.where.not(id: current_boards.pluck(:id)).order(:name) }
    team_boards = teams.map { |t| t.team_boards.includes(:board).where.not(board_id: current_board_ids) }
    team_boards.flatten
    # []
  end

  def supporters
    team_users.includes(:user).where(role: ["supporter", "member", "restricted"]).distinct.map(&:user)
  end

  def supervisors
    team_users.includes(:user).where(role: ["supervisor", "admin"]).distinct.map(&:user)
  end

  def startup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/accounts/sign-in?username=#{username}"
  end

  def public_url
    profile&.public_url
  end

  def bg_color
    profile&.bg_color
  end

  def boards_by_most_used
    board_ids = word_events.group(:board_id).count.sort_by { |_k, v| v }.reverse.to_h.keys
    Board.where(id: board_ids)
  end

  def go_to_boards
    favorite_boards.any? ? favorite_boards : boards_by_most_used
  end

  def most_used_board
    @most_used_board ||= boards_by_most_used.first
  end

  def go_to_words
    settings["go_to_words"] || Board.common_words
  end

  def recently_used_boards
    # word_events.includes(:board).where("created_at >= ?", 1.week.ago).order("created_at DESC").map(&:board).uniq
    child_boards.includes(board: :word_events).where("word_events.created_at >= ?", 1.week.ago).order("word_events.created_at DESC").uniq
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      username: username,
      passcode: passcode,
      last_sign_in_at: last_sign_in_at,
      sign_in_count: sign_in_count,
      can_edit: viewing_user&.can_add_boards_to_account?([id]),
      is_owner: viewing_user&.id == user_id,
      pro: user.pro?,
      free_trial: user.free_trial?,
      admin: user.admin?,
      parent_name: user.display_name,
      name: name,
      most_used_board: { id: most_used_board&.id, name: most_used_board&.name },
      recently_used_boards: recently_used_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, board_type: b.board_type, board_id: b.board_id } },
      heat_map: heat_map,
      profile: profile&.api_view(viewing_user),
      startup_url: startup_url,
      public_url: public_url,
      week_chart: week_chart,
      most_clicked_words: most_clicked_words,
      teams: teams.map { |t| t.index_api_view(viewing_user) },
      settings: settings,
      details: details,
      user_id: user_id,
      go_to_words: go_to_words,
      go_to_boards: go_to_boards.map { |board| { id: board.id, name: board.name, display_image_url: board.display_image_url } },
      avatar_url: profile&.avatar_url,
      supporters: supporters.map { |s| { id: s.id, name: s.name, email: s.email } },
      supervisors: supervisors.map { |s| { id: s.id, name: s.name, email: s.email } },
      boards: child_boards.map { |cb| { id: cb.id, name: cb.board.name, board_type: cb.board.board_type, board_id: cb.board_id, display_image_url: cb.board.display_image_url, favorite: cb.favorite, published: cb.published, added_by: cb.created_by&.display_name, added_by_id: cb.created_by&.id, board_owner_id: cb.board.user_id, board_owner_name: cb.board.user&.display_name, most_used: cb.board_id == most_used_board&.id, can_edit: viewing_user&.id == user_id } },
      can_sign_in: can_sign_in?,
      available_boards: available_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, board_type: b.board_type, word_sample: b.word_sample } },
      # teams_boards: available_teams_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, board_type: b.board_type } },
      teams_boards: available_teams_boards.map { |tb| { id: tb.board_id, name: tb.board.name, board_type: tb.board.board_type, display_image_url: tb.board.display_image_url, added_by: tb.created_by&.display_name, added_by_id: tb.created_by&.id, word_sample: tb.board.word_sample } },
    }
  end

  def index_api_view
    {
      id: id,
      username: username,
      name: name,
      parent_name: user.display_name,
      user_id: user_id,
      last_sign_in_at: last_sign_in_at&.strftime("%a, %b %e at %l:%M %p"),
      sign_in_count: sign_in_count,
      can_edit: user.admin?,
      pro: user.pro?,
      free_trial: user.free_trial?,
      admin: user.admin?,
      can_sign_in: can_sign_in?,
      profile: profile&.api_view,
      week_chart: week_chart,
      avatar_url: profile&.avatar_url,
      supporters: supporters.map { |s| { id: s.id, name: s.name, email: s.email } },
      supervisors: supervisors.map { |s| { id: s.id, name: s.name, email: s.email } },
    }
  end
end
