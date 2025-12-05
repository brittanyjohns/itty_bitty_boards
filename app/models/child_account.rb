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
#  vendor_id              :bigint
#
class ChildAccount < ApplicationRecord
  # devise :database_authenticatable, :trackable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  belongs_to :user, optional: true
  belongs_to :vendor, optional: true
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

  # scope :with_artifacts, -> { includes(:profile, :images, :word_events, :user, teams: [:team_users, :team_boards], child_boards: [:board]) }
  scope :with_artifacts, -> {
          includes(
            :profile,
            :user,
            :word_events,
            child_boards: :board,
            teams: [
              :team_users,
              :team_boards,
            ],
          )
        }
  scope :with_teams, -> { includes(teams: [:team_users]) }
  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }
  scope :with_boards, -> { includes(child_boards: :board) }

  def self.valid_credentials?(username, password_to_set)
    account = ChildAccount.find_by(username: username, passcode: password_to_set)
    if account
      Rails.logger.info "Valid credentials for #{username} account id #{account.id}"
      account
    else
      Rails.logger.info "Invalid credentials for #{username}"
      nil
    end
  end

  def update_audio
    Rails.logger.info "Updating audio for profile: #{profile.slug}"
    if profile
      profile.update_intro_audio_url
      profile.update_bio_audio_url
      profile.save!
      Rails.logger.info "Audio updated for profile: #{profile.slug}"
    else
      Rails.logger.error "Profile not found for audio update"
    end
  end

  def reset_authentication_token!
    self.authentication_token = SecureRandom.hex(10)
    save!
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

  def paid_plan?
    user&.paid_plan? || false
  end

  def favorite_boards
    if paid_plan? || user&.vendor?
      child_boards.where(favorite: true).includes(:board).map(&:board)
    else
      Board.public_boards
    end
  end

  def role
    if user&.vendor?
      "vendor"
    else
      "user"
    end
  end

  def vendor?
    user&.vendor? || false
  end

  def vendor_api_view(viewing_user = nil)
    cached_user = user
    is_vendor = cached_user&.vendor?
    cached_profile = profile
    cached_most_used_board = most_used_board
    cached_supporters = supporters
    cached_supervisors = supervisors
    cached_go_to_boards = go_to_boards
    cached_most_used_words = most_clicked_words

    {
      id: id,
      username: username,
      passcode: passcode,
      last_sign_in_at: last_sign_in_at,
      sign_in_count: sign_in_count,
      board_week_chart: board_week_chart,
      can_edit: viewing_user&.can_add_boards_to_account?([id]),
      is_owner: viewing_user&.id == user_id,
      is_vendor: is_vendor,
      vendor: is_vendor ? cached_user.vendor.api_view(viewing_user) : nil,
      vendor_profile: is_vendor ? cached_profile.api_view(viewing_user) : nil,
      pro: cached_user.pro?,
      free_trial: cached_user.free_trial?,
      admin: cached_user.admin?,
      parent_name: cached_user.display_name,
      name: name,
      most_used_board: {
        id: cached_most_used_board&.id,
        name: cached_most_used_board&.name,
      },
      recently_used_boards: recently_used_boards.map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          board_id: b.board_id,
        }
      end,
      heat_map: heat_map,
      profile: cached_profile&.api_view(viewing_user),
      startup_url: startup_url,
      public_url: public_url,
      week_chart: week_chart,
      most_clicked_words: most_clicked_words,
      teams: teams.map { |t| t.index_api_view(viewing_user) },
      settings: settings,
      details: details,
      user_id: user_id,
      go_to_words: go_to_words,
      go_to_boards: cached_go_to_boards.map do |board|
        {
          id: board.id,
          name: board.name,
          display_image_url: board.display_image_url,
        }
      end,
      avatar_url: cached_profile&.avatar_url,
      intro_audio_url: cached_profile&.intro_audio_url,
      bio_audio_url: cached_profile&.bio_audio_url,
      supporters: cached_supporters.map { |s| { id: s.id, name: s.name, email: s.email } },
      supervisors: cached_supervisors.map { |s| { id: s.id, name: s.name, email: s.email } },
      boards: child_boards.map do |cb|
        b = cb.board
        {
          id: cb.id,
          name: b.name,
          board_type: b.board_type,
          board_id: cb.board_id,
          display_image_url: b.display_image_url,
          preset_display_image_url: b.preset_display_image_url,
          favorite: cb.favorite,
          published: cb.published,
          added_by: cb.created_by&.display_name,
          added_by_id: cb.created_by&.id,
          board_owner_id: b.user_id,
          board_owner_name: b.user&.display_name,
          most_used: cb.board_id == cached_most_used_board&.id,
          can_edit: viewing_user&.id == user_id,
        }
      end,
      can_sign_in: can_sign_in?,
      available_boards: available_boards.map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          word_sample: b.word_sample,
        }
      end,
      teams_boards: available_teams_boards.map do |tb|
        b = tb.board
        {
          id: tb.board_id,
          name: b.name,
          board_type: b.board_type,
          display_image_url: b.display_image_url,
          added_by: tb.created_by&.display_name,
          added_by_id: tb.created_by&.id,
          word_sample: b.word_sample,
        }
      end,
    }
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
    slug = username&.parameterize
    unless slug
      Rails.logger.error "\nUsername is nil, cannot create profile\n"
      return
    end
    if Profile.find_by(slug: slug)
      slug = "#{slug}-#{id}"
    end
    profile = Profile.create!(profileable: self, username: username, slug: slug)
    profile.set_fake_avatar
    profile.save!
    profile
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

  def can_view_board?(board_id)
    return false unless board_id
    return true if child_boards.exists?(board_id: board_id)
    return true if teams.joins(:team_boards).exists?(team_boards: { board_id: board_id })
    false
  end

  # def available_boards
  #   current_board_ids = self.child_boards.distinct.pluck(:board_id)
  #   current_boards = Board.where(id: current_board_ids)
  #   user.boards.where.not(id: current_boards.pluck(:id)).order(:name)
  # end

  def available_boards
    used_ids = child_boards.select(:board_id)
    user.boards.where.not(id: used_ids).order(:name) # add includes as needed
  end

  # def available_teams_boards
  #   current_board_ids = self.child_boards.distinct.pluck(:board_id)
  #   team_boards = teams.map { |t| t.team_boards.includes(:board).where.not(board_id: current_board_ids) }
  #   team_boards.flatten
  # end

  def available_teams_boards
    used_ids = child_boards.select(:board_id)
    TeamBoard.includes(:board, :created_by)
             .where(team_id: teams.select(:id))
             .where.not(board_id: used_ids)
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

  def display_name
    name.presence || username
  end

  def plan_type
    user&.plan_type || "free"
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
    gt_boards = favorite_boards.any? ? favorite_boards : boards_by_most_used
    if gt_boards.none?
      # Handle case where there are no boards to go to
      gt_boards = Board.public_boards.limit(5)
    end
    gt_boards
  end

  def most_used_board
    @most_used_board ||= boards_by_most_used.first
  end

  def go_to_words
    settings["go_to_words"] || Board.common_words
  end

  def voice_settings
    settings["voice"] = { name: "alloy", speed: 1, pitch: 1, volume: 1, rate: 1, language: "en-US" } unless settings["voice"]
    settings["voice"]
  end

  def voice
    voice_settings["name"] || user.voice || "alloy"
  end

  def language
    voice_settings["language"] || user.language || "en-US"
  end

  def recently_used_boards
    # word_events.includes(:board).where("created_at >= ?", 1.week.ago).order("created_at DESC").map(&:board).uniq
    child_boards.includes(board: :word_events).where("word_events.created_at >= ?", 1.week.ago).order("word_events.created_at DESC").uniq
  end

  def api_view(viewing_user = nil)
    cached_user = user
    is_vendor = cached_user&.vendor?
    cached_profile = profile
    cached_most_used_board = most_used_board
    cached_supporters = supporters
    cached_supervisors = supervisors
    cached_go_to_boards = go_to_boards

    {
      id: id,
      username: username,
      passcode: passcode,
      last_sign_in_at: last_sign_in_at,
      sign_in_count: sign_in_count,
      can_edit: viewing_user&.can_add_boards_to_account?([id]),
      is_owner: viewing_user&.id == user_id,
      is_vendor: is_vendor,
      vendor: is_vendor ? vendor&.api_view(viewing_user) : nil,
      vendor_profile: is_vendor ? cached_profile&.api_view(viewing_user) : nil,
      pro: cached_user.pro?,
      free_trial: cached_user.free_trial?,
      admin: cached_user.admin?,
      parent_name: cached_user.display_name,
      parent_email: cached_user.email,
      plan_type: plan_type,
      name: name,
      layout: layout,
      most_used_board: {
        id: cached_most_used_board&.id,
        name: cached_most_used_board&.name,
      },
      recently_used_boards: recently_used_boards.map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          board_id: b.board_id,
        }
      end,
      heat_map: heat_map,
      profile: cached_profile&.api_view(viewing_user),
      startup_url: startup_url,
      public_url: public_url,
      week_chart: week_chart,
      most_clicked_words: most_clicked_words,
      teams: teams.map { |t| t.index_api_view(viewing_user) },
      settings: settings,
      details: details,
      user_id: user_id,
      go_to_words: go_to_words,
      go_to_boards: cached_go_to_boards.map do |board|
        {
          id: board.id,
          name: board.name,
          slug: board.slug,
          ionic_icon: board.ionic_icon,
          display_image_url: board.display_image_url,
        }
      end,
      avatar_url: cached_profile&.avatar_url,
      intro_audio_url: cached_profile&.intro_audio_url,
      bio_audio_url: cached_profile&.bio_audio_url,
      supporters: cached_supporters.map { |s| { id: s.id, name: s.name, email: s.email } },
      supervisors: cached_supervisors.map { |s| { id: s.id, name: s.name, email: s.email } },
      boards: child_boards.order(:created_at).map do |cb|
        b = cb.board
        {
          id: cb.id,
          name: b.name,
          board_type: b.board_type,
          board_id: cb.board_id,
          display_image_url: b.display_image_url,
          favorite: cb.favorite,
          published: cb.published,
          added_by: cb.created_by&.display_name,
          added_by_id: cb.created_by&.id,
          board_owner_id: b.user_id,
          board_owner_name: b.user&.display_name,
          most_used: cb.board_id == cached_most_used_board&.id,
          can_edit: viewing_user&.id == user_id,
        }
      end,
      can_sign_in: can_sign_in?,
      available_boards: available_boards.map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          word_sample: b.word_sample,
        }
      end,
      teams_boards: available_teams_boards.map do |tb|
        b = tb.board
        {
          id: tb.board_id,
          name: b.name,
          board_type: b.board_type,
          display_image_url: b.display_image_url,
          added_by: tb.created_by&.display_name,
          added_by_id: tb.created_by&.id,
          word_sample: b.word_sample,
        }
      end,
    }
  end

  def index_api_view
    @boards = boards.all.order(:name)
    @child_boards = child_boards.includes(:board)
    current_board_list = @child_boards.map(&:name)
    current_board_list = current_board_list ? current_board_list.join(", ").truncate(150) : nil
    {
      id: id,
      username: username,
      name: name,
      parent_name: user.display_name,
      board_count: @child_boards.size,
      board_list_sample: current_board_list,
      communicator_board_ids: @child_boards.pluck(:original_board_id),
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
