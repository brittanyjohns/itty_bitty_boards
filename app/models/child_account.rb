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
#  layout                 :jsonb
#  owner_id               :bigint
#  is_demo                :boolean          default(FALSE)
#  status                 :string           default("sandbox"), not null
#
class ChildAccount < ApplicationRecord
  # devise :database_authenticatable, :trackable
  # devise :database_authenticatable, :registerable,
  #        :recoverable, :rememberable, :validatable,
  #        authentication_keys: [:username]

  # Communicator lifecycle:
  #   sandbox — no login, board-capped scratch space (old "demo")
  #   loaner  — real login + full boards, owned by an SLP on a child's behalf;
  #             counts against the owner's slot
  #   active  — claimed/owned by the family; counts against their plan
  STATUSES = %w[sandbox loaner active].freeze
  SANDBOX = "sandbox".freeze
  LOANER  = "loaner".freeze
  ACTIVE  = "active".freeze

  DEMO_ACCOUNT_BOARD_LIMIT = 3
  # Board cap for the MySpeak demo communicator a Free user gets. Stored per
  # account in settings["demo_board_limit"]. Held at the same floor as
  # DEMO_ACCOUNT_BOARD_LIMIT so Free families get a usable starter set (3
  # boards) on their demo communicator, not just one.
  FREE_DEMO_BOARD_LIMIT = 3

  # Sanity ceiling on dashboard boards per communicator. Assigned clones are
  # deliberately excluded from the owner's board-limit count (the original
  # already counted), so without a per-communicator cap the assign endpoints
  # could mint unlimited board rows. 80 matches ChildBoard#toggle_favorite's
  # favorites cap — a dashboard can't meaningfully hold more.
  def self.max_assigned_boards
    ENV.fetch("MAX_ASSIGNED_BOARDS_PER_COMMUNICATOR", 80).to_i
  end

  def at_assigned_board_limit?(adding = 1)
    child_boards.count + adding > self.class.max_assigned_boards
  end

  belongs_to :user, optional: true
  belongs_to :vendor, optional: true
  belongs_to :owner, class_name: "User", optional: true
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
  include BoardsHelper

  # validates :passcode, presence: true, on: :create
  # validates :passcode, length: { minimum: 6 }, on: :create

  validates :username, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  # Passcodes are optional regardless of status. `promote_to_loaner!`
  # still mints one when none was supplied, so the "promote" path
  # produces a working sign-in by default — but no rule blocks a
  # loaner/active without a passcode or a sandbox with one.

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
  # Lifecycle scopes. demo_accounts/paid_accounts are kept as thin aliases
  # during the frontend cutover (F1) and removed when no callers remain.
  scope :sandbox, -> { where(status: SANDBOX) }
  scope :loaner,  -> { where(status: LOANER) }
  scope :active,  -> { where(status: ACTIVE) }
  scope :demo_accounts, -> { sandbox }
  scope :paid_accounts, -> { where.not(status: SANDBOX) }

  # Soft-archive (issue #165). Archived sandboxes disappear from every
  # default association/query (slot counters, communicator lists, status
  # group-by) so a pro can stash a planning workspace without losing the
  # boards. Use `.with_archived` or `.archived` to read past the scope.
  scope :archived,     -> { unscope(where: :archived_at).where.not(archived_at: nil) }
  scope :with_archived, -> { unscope(where: :archived_at) }
  default_scope { where(archived_at: nil) }

  before_validation :set_status_from_is_demo, on: :create
  before_save :sync_is_demo_alias
  before_save :set_owner_if_missing, if: -> { owner.nil? && user.present? }
  before_validation :set_username_if_missing, if: -> { username.blank? }

  # AAC personalization fields, stored in the details jsonb (same pattern as
  # details["interests"] — no columns). They feed CommunicatorProfile.for so
  # word-suggestion AI calls and the Board Builder's template recommendation
  # can be personalized without the picker being re-filled every time.
  AAC_PROFILE_FIELDS = {
    "aac_level" => CommunicatorProfile::AAC_LEVELS,
    "vocab_type" => CommunicatorProfile::VOCAB_TYPES,
    "age_band" => CommunicatorProfile::AGE_BANDS,
    "glp_stage" => CommunicatorProfile::GLP_STAGES,
  }.freeze

  # glp_stage is the lone integer profile field (NLA stage 1–6); the rest are
  # string enums. Normalization/validation below branch on this so an integer
  # isn't downcased into a string that fails the GLP_STAGES inclusion check.
  INTEGER_PROFILE_FIELDS = %w[glp_stage].freeze

  AAC_PROFILE_FIELDS.each_key do |field|
    define_method(field) { details&.dig(field) }
    define_method("#{field}=") do |value|
      self.details = (details || {}).merge(field => value)
    end
  end

  before_validation :normalize_aac_profile_fields
  validate :validate_aac_profile_fields

  def set_username_if_missing
    if name.present?
      self.username = name.parameterize
    else
      self.username = "comm#{SecureRandom.hex(4)}"
    end
  end

  # Runs on every save path (typed setter or wholesale details= from the
  # update controller): normalizes each profile key (downcases/strips the
  # string enums; coerces glp_stage to an integer) and drops blank ones, so
  # clearing a field is always allowed.
  def normalize_aac_profile_fields
    return if details.blank?

    AAC_PROFILE_FIELDS.each_key do |field|
      next unless details.key?(field)

      if INTEGER_PROFILE_FIELDS.include?(field)
        # Coerce to integer (handles "3" and 3). Blank clears the key; an
        # out-of-range value survives to fail validation below.
        value = details[field]
        if value.blank?
          details.delete(field)
        else
          details[field] = value.to_i
        end
      else
        value = details[field].to_s.strip.downcase
        if value.blank?
          details.delete(field)
        else
          details[field] = value
        end
      end
    end
  end

  def validate_aac_profile_fields
    return if details.blank?

    AAC_PROFILE_FIELDS.each do |field, allowed|
      value = details[field]
      next if value.blank?

      unless allowed.include?(value)
        errors.add(field.to_sym, "must be one of: #{allowed.join(', ')}")
      end
    end
  end

  def set_owner_if_missing
    self.owner = user
  end

  # Lifecycle predicates
  def sandbox? = status == SANDBOX
  def loaner?  = status == LOANER
  def active?  = status == ACTIVE

  # --- Fallback mode (issue #255) --------------------------------------------
  # A communicator that still exists but exceeds the owner's slot limit *because
  # the account downgraded to Free*. It keeps its boards, MySpeak/profile, and
  # public_url, but private passcode sign-in is blocked (`can_sign_in?` returns
  # false; the controller redirects to the public page). Read-only on the public
  # fallback — no board editing.
  #
  # The marker is only ever set/cleared by User#reconcile_communicator_fallback!,
  # so a fresh Free signup (capped at 1 communicator) is never flagged — this
  # state is only ever a consequence of a downgrade. It clears automatically on
  # re-upgrade when a slot frees up.
  FALLBACK_MODE_KEY = "fallback_mode".freeze

  def fallback_mode?
    settings.present? && settings[FALLBACK_MODE_KEY] == true
  end

  def enter_fallback!(reason: "downgrade")
    return self if fallback_mode?
    self.settings ||= {}
    self.settings[FALLBACK_MODE_KEY] = true
    self.settings["fallback_since"] = Time.current
    self.settings["fallback_reason"] = reason
    save!
    self
  end

  def exit_fallback!
    return self unless fallback_mode?
    self.settings ||= {}
    self.settings.delete(FALLBACK_MODE_KEY)
    self.settings.delete("fallback_since")
    self.settings.delete("fallback_reason")
    save!
    self
  end

  # Can `user` edit the communicator object itself (name, username, voice,
  # layout, safety info)? Distinct from `can_edit` in api_view, which
  # answers "can this user curate boards on this communicator." Spec:
  # marketing/.claude-notes/handoff-workflow.md (Permissions matrix).
  def editable_by?(user)
    user.present? && (user.id == owner_id || user.admin?)
  end

  # Most-recent Board Builder root still attached to this communicator, if any.
  # Detector for the re-run duplicate guard (issue #269): the wizard marks each
  # root board settings["builder_root"] = true. Deletion-safe — if the user
  # deletes the set, the join row goes with it, so this returns nil and a
  # re-run is treated as a fresh build.
  def board_builder_root
    boards.where("COALESCE((boards.settings->>'builder_root')::boolean, false)")
          .order("boards.created_at DESC")
          .first
  end

  # `is_demo` is derived from status now. The DB column is retained until the
  # frontend cutover (F1) is complete, then dropped. Writes to `is_demo` flow
  # into `status` for backwards compatibility.
  def is_demo
    sandbox?
  end

  alias_method :is_demo?, :is_demo

  def is_demo=(value)
    truthy = ActiveModel::Type::Boolean.new.cast(value)
    # Only flip from sandbox <-> active here. Loaner is set explicitly via the
    # provisioning path (B3). Explicit writes to `is_demo` shouldn't silently
    # demote a loaner.
    if truthy
      self.status = SANDBOX
    elsif !loaner?
      self.status = ACTIVE
    end
    super(truthy) if has_attribute?(:is_demo)
  end

  def set_status_from_is_demo
    # New records that only set the legacy boolean still get a sensible status.
    return if status_changed? || STATUSES.include?(status)
    self.status = self[:is_demo] ? SANDBOX : ACTIVE
  end

  # Keep the legacy boolean in sync with status while the column lives, so
  # any caller still reading the raw attribute sees a consistent value.
  def sync_is_demo_alias
    return unless has_attribute?(:is_demo)
    desired = sandbox?
    self[:is_demo] = desired if self[:is_demo] != desired
  end

  def self.valid_credentials?(username, password_to_set)
    account = ChildAccount.find_by(username: username, passcode: password_to_set)
    Rails.logger.error("Invalid credentials for #{username}") unless account
    account
  end

  # Promote a sandbox or active communicator to a loaner.
  #
  # Sandbox → loaner: provisions a passcode (uses the caller's if
  # supplied, otherwise mints one) and lifts the sandbox board cap.
  #
  # Active → loaner (issue #164): always rotates the passcode. The SLP
  # knew the active's credentials; once the family takes over, the SLP
  # shouldn't retain credential access. Caller-supplied `passcode:` is
  # honored so an SLP can intentionally hand over a known password.
  #
  # Idempotent on a loaner.
  def promote_to_loaner!(passcode: nil)
    return self if loaner?

    from_active = active?

    self.status = LOANER
    self.loaner_started_at ||= Time.current

    if passcode.present?
      self.passcode = passcode
    elsif self.passcode.blank? || from_active
      # Mint a fresh passcode whenever sandbox lacks one, or always on
      # active → loaner (the SLP forfeits their old credential access).
      self.passcode = SecureRandom.alphanumeric(8)
    end

    # Sandbox board cap was per-account in settings["demo_board_limit"];
    # remove it so the owner's plan board limit applies.
    self.settings ||= {}
    self.settings.delete("demo_board_limit")
    # Clear the claimed_at watermark — if this active was previously
    # claimed by the SLP themself, re-lending starts a fresh loan.
    self.claimed_at = nil if from_active

    save!
    self
  end

  # Promote a sandbox communicator to a full, owned `active` account.
  #
  # Used when a Free user (whose self-creates are forced to sandbox) upgrades
  # to a paid plan — their sandbox communicators become full communicators with
  # sign-in (see User#reconcile_paid_sandbox_promotions!, issue #359). Mints a
  # passcode if none exists so sign-in actually works, and lifts the per-account
  # sandbox board cap so the owner's plan board limit applies.
  #
  # Idempotent on an already-active account; never demotes a loaner.
  def promote_to_active!
    return self if active?
    return self if loaner?

    self.status = ACTIVE
    self.passcode = SecureRandom.alphanumeric(8) if passcode.blank?

    self.settings ||= {}
    self.settings.delete("demo_board_limit")

    save!
    self
  end

  # Generate (or rotate) the claim token the parent uses to take over
  # this loaner. Loaner-only. The claim URL is built by the controller.
  def generate_claim_token!
    raise ArgumentError, "Only loaners can issue a claim token" unless loaner?
    self.claim_token = SecureRandom.urlsafe_base64(24)
    self.claim_token_sent_at = Time.current
    save!
    claim_token
  end

  def claim_link_url
    return nil if claim_token.blank?
    base = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base}/claim/#{claim_token}"
  end

  # Execute the SLP→parent hand-off (B4). Transfers ownership, swaps the
  # account onto the parent's plan, keeps the SLP on the team as a
  # supervisor by default, and marks the account active.
  #
  # Returns self. Raises ArgumentError on misuse and
  # Permissions::CommunicatorLimits::SlotFull when the parent has no
  # room (caller should rescue and surface an upgrade prompt).
  def claim_by!(user:)
    raise ArgumentError, "user is required" unless user
    raise ArgumentError, "Only loaners can be claimed" unless loaner?

    allowed, _http_status, error = Permissions::CommunicatorLimits.can_claim?(user: user)
    raise SlotFull, (error || "No claim slot available") unless allowed

    previous_owner = owner

    transaction do
      self.owner = user
      # `user` is the legacy parent field; the rest of the app uses it
      # for things like display_name and admin checks. Mirror owner so
      # account.parent_name reflects the new owner.
      self.user = user if has_attribute?(:user_id)
      self.status = ACTIVE
      self.claimed_at = Time.current
      self.claim_token = nil
      self.claim_token_sent_at = nil
      save!

      if previous_owner && previous_owner != user
        # Act on the communicator's OWN team, not whichever team happens
        # to sort first — a communicator may be on several teams.
        team = primary_team || ensure_team!(creator: user)
        pin_primary_team!(team)
        team.upsert_member!(previous_owner, "supervisor")
        team.upsert_member!(user, "admin")
        # Hand the team over to the new owner so they get full management
        # rights — `created_by_id` drives `is_owner` / `can_invite` in the
        # team api_view, so without this the new owner couldn't manage it.
        team.update!(created_by: user) unless team.created_by_id == user.id
        # Preserve the inherited dashboard boards as team boards so the new
        # owner can clear/curate the dashboard without losing them.
        register_dashboard_boards_on_team!(team)
      end
    end

    self
  end

  # Manual reclaim / end-loan (B5). Frees the SLP's slot immediately.
  # The account flips back to a no-login sandbox; the boards stay where
  # they are. Used by the owner UI and the reclaim job.
  def reclaim!(reason: "manual")
    raise ArgumentError, "Only loaners can be reclaimed" unless loaner?
    self.status = SANDBOX
    self.passcode = nil
    self.claim_token = nil
    self.claim_token_sent_at = nil
    self.reclaimed_at = Time.current
    self.settings ||= {}
    self.settings["reclaim_reason"] = reason
    save!
    self
  end

  class SlotFull < StandardError; end

  # Soft-archive a communicator (issues #165, #237). Allowed for sandbox
  # and active (owner-controlled) accounts. Loaner is excluded — it has
  # downstream effects (slot accounting, claim tokens, family ownership)
  # that need their own flow via `end_loan` / `reclaim!`.
  #
  # Archiving an active frees the owner's slot via the default scope,
  # matching how archived sandboxes drop out of the sandbox count. The
  # status field is preserved so unarchive can restore the original state;
  # we also stamp the pre-archive status in settings as an audit trail.
  def archive!(reason: "owner_request")
    if loaner?
      raise ArgumentError, "Loaner communicators must end the loan first (see end_loan / reclaim!)"
    end
    return self if archived_at.present?

    self.settings ||= {}
    self.settings["archive_reason"] = reason
    self.settings["archived_status"] = status
    self.archived_at = Time.current
    save!
    self
  end

  # Restore an archived communicator. If it was an active when archived,
  # re-check the owner's slot limit before un-archiving — archiving freed
  # the slot, so the owner may have filled it in the meantime.
  def unarchive!
    archived_status = settings&.dig("archived_status") || status

    if archived_status == ACTIVE && owner.present?
      allowed, _http_status, error =
        Permissions::CommunicatorLimits.can_create?(user: owner, status: ACTIVE)
      raise SlotFull, (error || "Maximum number of communicator accounts reached.") unless allowed
    end

    self.settings ||= {}
    self.settings.delete("archive_reason")
    self.settings.delete("archived_status")
    self.archived_at = nil
    save!
    self
  end

  def archived? = archived_at.present?

  # Surfaced on api_view so the frontend can render a countdown / "link
  # expires" copy without needing to know the reclaim job's cutoff.
  def loan_expires_at
    return nil unless loaner?
    anchor = claim_token_sent_at || loaner_started_at
    return nil if anchor.blank?
    anchor + LoanerReclaimJob::RECLAIM_AFTER
  end

  # The communicator's "own" team — the one created *for* it, whose
  # membership the handoff and owner checks act on. A communicator can
  # belong to multiple teams (its own, plus shared/board teams it's been
  # added to), so `teams.first` is unreliable (issue: handoff updated
  # the wrong team). Resolve deterministically:
  #   1. the team id pinned in settings (set by `ensure_team!` / claim),
  #   2. the namesake team auto-created at creation ("<name>'s Communication Team"),
  #   3. fall back to the oldest team (legacy single-team accounts).
  def primary_team
    pinned_id = settings&.dig("primary_team_id")
    if pinned_id
      pinned = teams.find_by(id: pinned_id)
      return pinned if pinned
    end
    namesake_team || teams.order(:id).first
  end

  # The team auto-created for this communicator, matched by the naming
  # convention used on creation (`child_accounts_controller#create` and
  # the MySpeak onboarding controller both use "<name>'s Communication
  # Team"). Best-effort: a renamed communicator won't match, which is why
  # `ensure_team!`/`claim_by!` pin the id in settings going forward.
  def namesake_team
    return nil if name.blank?
    teams.find_by(name: "#{name}'s Communication Team")
  end

  # Record which team is this communicator's primary/own team so
  # `primary_team` resolves it unambiguously regardless of join order or
  # later renames. Idempotent.
  def pin_primary_team!(team)
    return if team.nil?
    self.settings ||= {}
    return if settings["primary_team_id"] == team.id
    settings["primary_team_id"] = team.id
    save!
  end

  # Register the communicator's current dashboard boards as team boards on
  # `team`. This is the safety net behind non-destructive board removal: once
  # a board is also a team board, `ChildBoardsController#destroy` detaches it
  # from the dashboard instead of deleting it, and it stays available via the
  # team for re-adding. Idempotent — `Team#add_board!` skips boards already on
  # the team. Attributed to each board's owner (the original sharer).
  def register_dashboard_boards_on_team!(team)
    return unless team
    child_boards.includes(:board).find_each do |cb|
      board = cb.board
      next unless board
      team.add_board!(board, board.user_id || cb.created_by_id)
    end
  end

  # Ensure this communicator has a team. If it already does, return
  # it as-is. Otherwise create one with `creator` as the team-creator
  # AND as an `admin` team_user — i.e. the caller never has to follow
  # up with `team.upsert_member!(creator, "admin")`. Issue #226.
  #
  # `name:` lets callers override the default "<communicator>'s Team"
  # (e.g. the API controllers use "<communicator>'s Communication
  # Team"). Passing nil falls back to the default.
  def ensure_team!(creator:, name: nil)
    existing = primary_team
    if existing.present?
      pin_primary_team!(existing)
      return existing
    end

    team_name = name.presence || "#{self.name || "Communicator"}'s Team"
    team = Team.create!(name: team_name, created_by: creator)
    TeamAccount.create!(team: team, account: self)
    team.upsert_member!(creator, "admin") if creator
    pin_primary_team!(team)
    team
  end

  def update_audio(updated_voice)
    unless updated_voice
      Rails.logger.error "No voice provided for audio update"
      return
    end
    if profile
      SaveProfileAudioJob.perform_async(profile.id)
    else
      Rails.logger.error "Profile not found for audio update"
    end
    #  update boards audio as well
    board_ids = child_boards.pluck(:board_id).uniq
    if board_ids.empty?
      Rails.logger.info "UPDATE AUDIO  - No boards found for user_id #{user_id}"
      return
    end
    Rails.logger.info "UPDATE AUDIO  - Updating audio for boards: #{board_ids.count} boards found for user_id #{user_id}"
    board_ids.each_slice(5) do |batch|
      UpdateBoardsVoiceJob.perform_async(batch, updated_voice, language)
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
    child_boards.where(favorite: true)
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
      can_edit_communicator: editable_by?(viewing_user),
      is_owner: viewing_user&.id == user_id,
      is_vendor: is_vendor,
      layout: layout,
      status: status,
      is_demo: is_demo?,
      archived_at: archived_at,
      claim_token: claim_token,
      claim_url: claim_link_url,
      loaned_at: loaner_started_at,
      claimed_at: claimed_at,
      loan_expires_at: loan_expires_at,
      voice: voice,
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
      aac_level: aac_level,
      vocab_type: vocab_type,
      age_band: age_band,
      glp_stage: glp_stage,
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
          can_edit: viewing_user&.id == b.user_id,
          # Removing a board from the dashboard is a curation action gated on
          # *communicator* ownership, not board ownership — so a hand-off owner
          # can clear inherited boards they don't own. (Removal is
          # non-destructive: see ChildBoardsController#destroy.)
          can_remove: viewing_user.present? && (viewing_user.id == owner_id || viewing_user.admin?),
        }
      end,
      can_sign_in: can_sign_in?,
      fallback_mode: fallback_mode?,
      fallback_since: settings&.dig("fallback_since"),
      available_boards: available_boards_for_user(viewing_user).map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          word_sample: b.word_sample,
          predefined: b.predefined,
          user_id: b.user_id,
          is_owner: b.user_id == viewing_user&.id,
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

  def audit_logging_disabled?
    settings.present? && settings["disable_audit_logging"] == true
  end

  def send_setup_email(sending_user)
    CommunicationAccountMailer.setup_email(self, sending_user).deliver_later
  end

  def create_profile!
    return if profile.present?
    slug = sluggify_for_profile(username)
    unless slug
      Rails.logger.error "\nUsername is nil, cannot create profile\n"
      return
    end
    random_id = SecureRandom.hex(4)
    if Profile.find_by(slug: slug)
      slug = "#{slug}-#{random_id}"
    end
    profile = Profile.create!(profileable: self, username: username, slug: slug)
    profile.set_fake_avatar
    profile.save!
    profile
  end

  # Profile slugs must match Profile::SLUG_FORMAT (3–40 lowercase letters /
  # digits / hyphens, no leading-or-trailing hyphen). `String#parameterize`
  # keeps underscores, so legacy usernames like "child_1" would otherwise
  # produce a slug that fails the format validation. We sanitize aggressively
  # here and pad short results so any non-empty username yields a valid slug.
  def sluggify_for_profile(value)
    return nil if value.nil?
    base = value.to_s.parameterize
                .tr("_", "-")
                .gsub(/-+/, "-")
                .gsub(/^-+|-+$/, "")
                .downcase
    base = "u-#{base}" if base.length.positive? && base.length < 3
    base.presence
  end

  def print_credentials
    puts "UserId: #{user_id} Username: #{username} Password: #{passcode}"
  end

  def can_sign_in?(user_context = nil)
    # Sandboxes are no-login demo accounts — they never have a passcode, so
    # nobody (not even an admin) can sign into one. Guard first so a sandbox
    # owned by a paid/trial user can't fall through to the plan check below and
    # wrongly report can_sign_in: true.
    return false if sandbox?

    if user_context && user_context.admin?
      return true
    end

    if self.user&.admin?
      return true
    end

    # Fallback-mode communicators (over the Free slot limit after a downgrade)
    # can't use private passcode sign-in. A system admin (handled above) still
    # bypasses for support access; the public MySpeak page stays open. #255.
    return false if fallback_mode?

    if user
      if user.paid_plan? || user.vendor?
        return true
      else
        user.free_trial? || false
      end
    else
      Rails.logger.error "No user provided for can_sign_in check"
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
    board_ids = child_boards.select(:board_id)
    user_boards = user.boards.where.not(id: board_ids).alphabetical
    #  predefined boards too
    # public_boards = Board.public_boards.where.not(id: board_ids)
    # user_boards.or(public_boards).order(:name)
  end

  def available_boards_for_user(viewing_user)
    if viewing_user.nil?
      return available_boards
    end
    if viewing_user.id == user_id
      available_boards
    else
      board_ids = child_boards.select(:board_id)
      viewing_user.boards.where.not(id: board_ids).order(:name)
    end
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

  # Read-only team members across all of this account's teams. Named
  # for backward-compat with the `supporters` field in `api_view`; new
  # canonical role set is just `member`. Issue #216.
  def supporters
    team_users.includes(:user).where(role: "member").distinct.map(&:user)
  end

  # Curators across all of this account's teams. `admin` is the
  # account owner, `supervisor` is the SLP / power collaborator.
  # Surfaced in `api_view` under the `supervisors` key. Issue #216.
  def supervisors
    team_users.includes(:user).where(role: %w[admin supervisor]).distinct.map(&:user)
  end

  def startup_url
    # A sandbox has no private sign-in, so don't advertise a sign-in URL for it.
    return nil if sandbox?

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
    settings["voice"] = { name: "polly:kevin", speed: 1, pitch: 1, volume: 1, rate: 1, language: "en-US" } unless settings["voice"]
    settings["voice"]
  end

  def voice
    voice_settings["name"] || "polly:kevin"
  end

  def voice_speed
    voice_settings["speed"] || 1
  end

  def voice=(voice_name)
    settings["voice"] ||= {}
    settings["voice"]["name"] = voice_name
    save!
  end

  def language
    voice_settings["language"] || user.language || "en-US"
  end

  include LocaleResolution

  def recently_used_boards
    # word_events.includes(:board).where("created_at >= ?", 1.week.ago).order("created_at DESC").map(&:board).uniq
    child_boards.includes(board: :word_events).where("word_events.created_at >= ?", 1.week.ago).order("word_events.created_at DESC").uniq
  end

  def update_board_layout(screen_size)
    self.layout = {}
    self.layout[screen_size] = {}
    child_boards.order(:position).each do |cb|
      cb.layout[screen_size] = cb.layout[screen_size] || { x: 0, y: 0, w: 1, h: 1 } # Set default layout
      cb_layout = cb.layout[screen_size].merge("i" => cb.id.to_s)
      cb.update(layout: { screen_size => cb_layout })
      self.layout[screen_size][cb.id] = cb_layout
    end
    self.save
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
      created_at: created_at,
      sign_in_count: sign_in_count,
      can_edit: viewing_user&.can_add_boards_to_account?([id]),
      can_edit_communicator: editable_by?(viewing_user),
      is_owner: viewing_user&.id == user_id || viewing_user&.admin?,
      is_vendor: is_vendor,
      layout: layout,
      status: status,
      is_demo: is_demo?,
      archived_at: archived_at,
      claim_token: claim_token,
      claim_url: claim_link_url,
      loaned_at: loaner_started_at,
      claimed_at: claimed_at,
      loan_expires_at: loan_expires_at,
      device_tag_url: device_tag_url,
      safety_id_url: safety_id_url,
      voice: voice,
      vendor: is_vendor ? vendor&.api_view(viewing_user) : nil,
      vendor_profile: is_vendor ? cached_profile&.api_view(viewing_user) : nil,
      pro: cached_user.pro?,
      free_trial: cached_user.free_trial?,
      admin: cached_user.admin?,
      parent_name: cached_user.display_name,
      parent_email: cached_user.email,
      plan_type: plan_type,
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
          bg_color: b.bg_color,
          text_color: b.text_color,
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
      aac_level: aac_level,
      vocab_type: vocab_type,
      age_band: age_band,
      glp_stage: glp_stage,
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
      boards: child_boards.includes(:original_board, :board).order(:created_at).map do |cb|
        b = cb.board
        og_board = cb.original_board
        {
          id: cb.id,
          name: b.name,
          bg_color: b.bg_color,
          original_board_id: cb.original_board_id,
          text_color: b.text_color,
          board_type: b.board_type,
          board_id: cb.board_id,
          communicator_board_id: cb.id,
          display_image_url: b.display_image_url || og_board&.display_image_url,
          favorite: cb.favorite,
          published: cb.published,
          added_by: cb.created_by&.display_name,
          added_by_id: cb.created_by&.id,
          board_owner_id: b.user_id,
          board_owner_name: b.user&.display_name,
          most_used: cb.board_id == cached_most_used_board&.id,
          can_edit: viewing_user&.id == b.user_id,
          # Removing a board from the dashboard is a curation action gated on
          # *communicator* ownership, not board ownership — so a hand-off owner
          # can clear inherited boards they don't own. (Removal is
          # non-destructive: see ChildBoardsController#destroy.)
          can_remove: viewing_user.present? && (viewing_user.id == owner_id || viewing_user.admin?),
        }
      end,
      can_sign_in: can_sign_in?,
      fallback_mode: fallback_mode?,
      fallback_since: settings&.dig("fallback_since"),
      available_boards: available_boards_for_user(viewing_user).map do |b|
        {
          id: b.id,
          name: b.name,
          display_image_url: b.display_image_url,
          board_type: b.board_type,
          word_sample: b.word_sample,
          predefined: b.predefined,
          user_id: b.user_id,
          is_owner: b.user_id == viewing_user&.id,
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

  # Minimal public-safe view for unauthenticated profile endpoints.
  # The full api_view leaks parent_email, supporter/supervisor emails,
  # passcode, claim tokens, and internal settings. This view exposes
  # only what the public page UI actually needs.
  def public_api_view
    cached_profile = profile
    {
      id: id,
      name: name,
      avatar_url: cached_profile&.avatar_url,
      voice: voice,
      boards: child_boards.includes(:board).where(favorite: true).map do |cb|
        b = cb.board
        {
          id: cb.id,
          name: b.name,
          board_type: b.board_type,
          display_image_url: b.display_image_url,
        }
      end,
    }
  end

  def index_api_view
    @boards = boards.all.alphabetical
    @child_boards = child_boards.includes(:board)
    current_board_list = @child_boards.map(&:name)
    current_board_list = current_board_list ? current_board_list.join(", ").truncate(150) : nil
    {
      id: id,
      status: status,
      username: username,
      name: name,
      parent_name: user.display_name,
      board_count: @child_boards.size,
      board_list_sample: current_board_list,
      communicator_board_ids: @child_boards.pluck(:original_board_id).compact,
      user_id: user_id,
      last_sign_in_at_str: last_sign_in_at&.strftime("%a, %b %e at %l:%M %p"),
      last_sign_in_at: last_sign_in_at,
      sign_in_count: sign_in_count,
      can_edit: user.admin?,
      pro: user.pro?,
      free_trial: user.free_trial?,
      admin: user.admin?,
      can_sign_in: can_sign_in?,
      fallback_mode: fallback_mode?,
      fallback_since: settings&.dig("fallback_since"),
      # profile: profile&.api_view,
      week_chart: week_chart,
      avatar_url: profile&.avatar_url,
      device_tag_url: device_tag_url,
      safety_id_url: safety_id_url,
      is_demo: is_demo?,
      voice: voice,
      supporters: supporters.map { |s| { id: s.id, name: s.name, email: s.email } },
      supervisors: supervisors.map { |s| { id: s.id, name: s.name, email: s.email } },
    }
  end

  def safety_id_url
    return nil unless profile&.safety_id_png&.attached?
    profile.url_for_attachment(profile.safety_id_png)
  end

  def device_tag_url
    return nil unless profile&.device_tag_png&.attached?
    profile.url_for_attachment(profile.device_tag_png)
  end
end
