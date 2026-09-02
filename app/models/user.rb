# == Schema Information
#
# Table name: users
#
#  id                              :bigint           not null, primary key
#  email                           :string           default(""), not null
#  encrypted_password              :string           default(""), not null
#  reset_password_token            :string
#  reset_password_sent_at          :datetime
#  remember_created_at             :datetime
#  sign_in_count                   :integer          default(0), not null
#  current_sign_in_at              :datetime
#  last_sign_in_at                 :datetime
#  current_sign_in_ip              :string
#  last_sign_in_ip                 :string
#  name                            :string
#  role                            :string
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  tokens                          :integer          default(0)
#  stripe_customer_id              :string
#  authentication_token            :string
#  jti                             :string           not null
#  invitation_token                :string
#  invitation_created_at           :datetime
#  invitation_sent_at              :datetime
#  invitation_accepted_at          :datetime
#  invitation_limit                :integer
#  invited_by_id                   :integer
#  invited_by_type                 :string
#  current_team_id                 :bigint
#  play_demo                       :boolean          default(TRUE)
#  settings                        :jsonb
#  base_words                      :string           default([]), is an Array
#  plan_type                       :string           default("free")
#  plan_expires_at                 :datetime
#  plan_status                     :string           default("active")
#  monthly_price                   :decimal(8, 2)    default(0.0)
#  yearly_price                    :decimal(8, 2)    default(0.0)
#  total_plan_cost                 :decimal(8, 2)    default(0.0)
#  uuid                            :uuid
#  child_lookup_key                :string
#  locked                          :boolean          default(FALSE)
#  organization_id                 :bigint
#  vendor_id                       :bigint
#  stripe_subscription_id          :string
#  temp_login_token                :string
#  temp_login_expires_at           :datetime
#  force_password_reset            :boolean          default(FALSE)
#  paid_plan_type                  :string
#  delete_account_token            :string
#  delete_account_token_expires_at :datetime
#  deleted_at                      :datetime
#  layout                          :jsonb
#  confirmation_token              :string
#  confirmed_at                    :datetime
#  confirmation_sent_at            :datetime
#  unconfirmed_email               :string
#
require "csv"

class User < ApplicationRecord
  default_scope { where(deleted_at: nil) }
  include Devise::JWT::RevocationStrategies::JTIMatcher
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :invitable, :trackable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  # Associations
  belongs_to :organization, optional: true
  belongs_to :editable_board, class_name: "Board", optional: true
  has_many :boards, -> { where(is_template: false) }, class_name: "Board", dependent: :destroy
  has_many :template_boards, -> { where(is_template: true) }, class_name: "Board", dependent: :destroy
  has_many :total_boards, class_name: "Board", dependent: :destroy
  has_many :board_images, through: :boards
  has_many :total_board_images, through: :total_boards, source: :board_images
  has_many :board_groups, dependent: :destroy
  has_many :menus, dependent: :destroy
  has_many :images, dependent: :destroy
  has_many :docs, dependent: :destroy
  has_many :user_docs, dependent: :destroy
  has_many :openai_prompts, dependent: :destroy
  has_many :team_users, dependent: :destroy
  belongs_to :current_team, class_name: "Team", optional: true
  has_many :word_events, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :credit_transactions, dependent: :destroy
  has_many :clinician_applications, dependent: :destroy
  has_secure_token :authentication_token
  # has_many :communicator_accounts, dependent: :destroy
  has_many :scenarios, dependent: :destroy
  has_many :created_teams, class_name: "Team", foreign_key: "created_by_id", dependent: :destroy
  has_one :profile, as: :profileable, dependent: :destroy
  belongs_to :vendor, optional: true
  has_many :board_screenshot_imports, dependent: :destroy
  has_many :board_exports, dependent: :destroy
  has_many :communicator_accounts,
           class_name: "ChildAccount",
           foreign_key: "owner_id",
           dependent: :destroy

  has_many :sandbox_communicator_accounts,
           -> { where(status: ChildAccount::SANDBOX) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  has_many :loaner_communicator_accounts,
           -> { where(status: ChildAccount::LOANER) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  has_many :active_communicator_accounts,
           -> { where(status: ChildAccount::ACTIVE) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  # Owned loaner+active accounts — what counts against the slot limit.
  has_many :slotted_communicator_accounts,
           -> { where(status: [ChildAccount::LOANER, ChildAccount::ACTIVE]) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  # Legacy aliases kept during the frontend cutover (issue #157). They
  # now resolve through status, not the legacy is_demo column.
  has_many :demo_communicator_accounts,
           -> { where(status: ChildAccount::SANDBOX) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  has_many :paid_communicator_accounts,
           -> { where(status: [ChildAccount::LOANER, ChildAccount::ACTIVE]) },
           class_name: "ChildAccount",
           foreign_key: "owner_id"

  # has_many :sent_messages, class_name: "Message", foreign_key: "sender_id", dependent: :destroy
  # has_many :received_messages, class_name: "Message", foreign_key: "recipient_id", dependent: :destroy

  has_many :page_follows, foreign_key: :follower_user_id, dependent: :destroy
  has_many :followed_pages, through: :page_follows, source: :page

  # Scopes
  scope :admin, -> { where(role: "admin") }
  scope :pro, -> { where(plan_type: "pro") }
  scope :free, -> { where(plan_type: "free") }
  scope :basic, -> { where(plan_type: "basic") }
  scope :plus, -> { where(plan_type: "plus") }
  scope :vendor, -> { where(role: "vendor") }
  scope :partner, -> { where(role: "partner") }

  scope :non_admin, -> { where("role IS NULL OR role != ?", "admin") }
  # Demo/internal accounts, recognised two ways:
  #   1. an email matching a known pattern (below, extensible via ENV), or
  #   2. an explicit settings["internal_account"] = true marker.
  #
  # (2) exists because pattern-matching alone kept missing real test accounts:
  # a testing session created speakanyway@gmail.com, testaria@gmail.com,
  # speak@test.com and friends, none of which match "@speakanyway.com", and
  # they went on to consume journey sends, bounce, and pollute growth metrics.
  # Mark those by hand with `users:internal:mark` rather than inventing ever
  # broader patterns that risk catching a real customer.
  #
  # This scope and #demo_user? MUST stay in agreement — the scope drives
  # admin/Mission Control metrics while the predicate gates Mailchimp journey
  # sends, so a divergence means the dashboards and the emails disagree about
  # who is real. Both derive from .demo_email_patterns + the same flag.
  DEMO_EMAIL_PATTERNS = ["bhannajohns+", "@speakanyway.com"].freeze
  INTERNAL_ACCOUNT_FLAG = "internal_account".freeze

  # Additional substrings via DEMO_EMAIL_PATTERNS (comma-separated), so a new
  # test-account convention doesn't need a deploy.
  def self.demo_email_patterns
    extra = ENV["DEMO_EMAIL_PATTERNS"].to_s.split(",").map(&:strip).reject(&:blank?)
    DEMO_EMAIL_PATTERNS + extra
  end

  def self.internal_account_condition
    { INTERNAL_ACCOUNT_FLAG => true }.to_json
  end

  # Built in Arel rather than a SQL string. The pattern list is variable-length,
  # so a string fragment would have to interpolate the `?` placeholders — safe
  # in fact, but indistinguishable from injection to Brakeman, and this reads
  # better anyway. `matches` compiles to ILIKE on Postgres.
  #
  # Columns come out table-qualified, which matters: this scope gets joined
  # (Mission Control joins boards for a per-user board count) and `boards` has
  # a `settings` column too, so an unqualified reference is ambiguous.
  scope :demo_accounts, -> {
    table = arel_table
    email_match = demo_email_patterns
      .map { |pattern| table[:email].matches("%#{pattern}%") }
      .reduce(:or)
    internal_flag = Arel::Nodes::InfixOperation.new(
      "@>", table[:settings], Arel::Nodes.build_quoted(internal_account_condition)
    )

    non_admin.where(email_match.or(internal_flag))
  }
  # Exact complement of demo_accounts (admins are never demo). Growth/usage
  # metrics use this so internal/test activity doesn't inflate the numbers.
  scope :non_demo, -> { where.not(id: demo_accounts.select(:id)) }
  # SQL counterpart of #paid_plan?: a paid tier whose status isn't a
  # non-paying one. basic_trial / trialing count as paid while active, same
  # as the instance method. Excludes UNPAID_STATUSES (canceled/paused/etc.)
  # so a stranded "basic + canceled" user is not counted as paying.
  scope :paid, -> {
    where("plan_status IS NULL OR plan_status NOT IN (?)", UNPAID_STATUSES)
      .where(
        "plan_type LIKE '%basic%' OR plan_type = 'pro' OR plan_type LIKE '%plus%' " \
        "OR plan_type LIKE '%premium%' OR (plan_type LIKE '%pro%' AND role = 'vendor')",
      )
  }
  scope :with_artifacts, -> { includes(user_docs: { doc: { image_attachment: :blob } }, docs: { image_attachment: :blob }) }

  include WordEventsHelper
  include StripeHelper
  include UsersHelper
  # Defaults for the display flags in `settings` — shared with ChildAccount so
  # a communicator and its owner can't disagree about an absent key.
  include DisplaySettingsDefaults
  # Constants
  # DEFAULT_ADMIN_ID = self.admin.first&.id
  DEFAULT_ADMIN_ID = Rails.env.development? ? 2 : 1
  TEMP_LOGIN_TOKEN_EXPIRY_HOURS = 4

  # Callbacks
  before_save :set_default_settings, unless: :settings?
  before_validation :set_uuid, on: :create
  before_save :ensure_settings, unless: :has_all_settings?

  before_destroy :delete_stripe_customer
  before_destroy :unassign_vendor

  # Every new signup lands on Free — the no-CC `basic_trial` soft trial was
  # removed (drafts/drop-basic-trial-option-a.md). The `plan_type` column
  # already defaults to "free"; this callback just applies the Free-tier
  # limits in-memory on create so the account has a board slot, a communicator
  # slot, and the AI monthly limit set from the start. The initial AI credit
  # grant follows on commit — see grant_signup_ai_allowance. Its size is the
  # plan's monthly allowance, read from CreditService::PLAN_MONTHLY_CREDITS
  # for the user's plan_type; don't restate the number here, it drifts.
  before_create :setup_new_user_free_plan
  before_save :setup_limits, if: :plan_type_changed?
  before_save :update_vendor, if: :plan_type_changed?

  # `past_due` is a grace state, not a downgrade — Stripe keeps retrying the
  # charge and access continues — so it needs an age, not a status check.
  # Stamping the entry moment here (rather than in each webhook) covers every
  # source that writes the status: Stripe invoice.payment_failed and
  # RevenueCat BILLING_ISSUE. DowngradePastDueJob times the grace window off
  # this stamp; leaving past_due drops it, so a recovered payer re-enters the
  # state with a fresh window.
  before_save :track_past_due_transition, if: :plan_status_changed?

  # Reconcile communicator fallback mode whenever the plan changes (issue #255).
  # Runs after save (so the new slot limits in `settings` are persisted) and in
  # both directions: a downgrade flags over-limit communicators, a re-upgrade
  # restores them as slots free up. See reconcile_communicator_fallback!.
  after_save :reconcile_communicator_fallback!, if: :saved_change_to_plan_type?

  # Promote sandbox communicators to full (active) accounts when the user lands
  # on a paid plan (issue #359). A Free user's self-creates are forced to
  # sandbox; without this, upgrading to Basic/Pro left those communicators stuck
  # in sandbox mode with sign-in disabled. Runs after save (new slot limits are
  # already in `settings`) on every plan change. See
  # reconcile_paid_sandbox_promotions!.
  after_save :reconcile_paid_sandbox_promotions!, if: :saved_change_to_plan_type?

  # Legacy welcome tokens + the plan's AI credit allowance land at SIGNUP, not
  # at email verification. The grant used to be deferred until the user
  # clicked the verification link, on the theory that a zero balance was a
  # free abuse gate that no future AI code path could forget to check — but
  # the cost fell on every honest account that hadn't opened its email yet,
  # which on day one is most of them. Verification is still stamped, still
  # emailed, and still means what it says; it just no longer gates AI.
  #
  # `after_commit`, never `after_create`: CreditService.grant_plan! opens its
  # own transaction, so from inside the create transaction a DB error there
  # would be swallowed by ensure_initial_grant!'s rescue while still marking
  # the outer transaction aborted — turning the COMMIT into a ROLLBACK and
  # taking the new user row with it. Same trap mark_email_verified! documents.
  after_commit :grant_signup_ai_allowance, on: :create

  def grant_signup_ai_allowance
    grant_welcome_tokens!
    grant_initial_plan_credits
  end

  def grant_initial_plan_credits
    CreditService.ensure_initial_grant!(self)
  end

  def following?(page)
    page_follows.exists?(followed_page_id: page.id)
  end

  def update_vendor
    return if vendor
    return unless role == "vendor" && id
    assigned_vendor = Vendor.find_by(user_id: id)
    if assigned_vendor
      self.vendor_id = assigned_vendor.id
    else
      new_vendor = Vendor.create(business_name: name || email, user_id: id)
      self.vendor_id = new_vendor.id
    end
  end

  attr_accessor :skip_plan_setup

  # before_create hook: put new signups on Free with the correct limits.
  # Mutates settings in-memory only (no save) since the record isn't
  # persisted yet. setup_free_limits sets paid_communicator_limit to the
  # FREE default, which already satisfies ensure_minimum_communicator_slot!.
  #
  # Only applies Free limits when the account is actually Free. Accounts
  # created with an explicit paid/basic_trial plan_type get their limits from
  # before_save :setup_limits (which fires on plan_type_changed?) — don't
  # clobber those here.
  def setup_new_user_free_plan
    self.plan_type = "free" if plan_type.blank?
    setup_free_limits if plan_type == "free"
  end

  # NOTE: `set_soft_trial_plan` was deleted here — the no-CC soft trial was
  # removed (drafts/drop-basic-trial-option-a.md) and nothing called the method
  # any more. It was the only way to *enter* basic_trial. The rest of the
  # basic_trial machinery stays until the cohort ages out: DowngradeSoftTrialJob,
  # RefreshFreeTierCreditsJob, the basic_trial branches in setup_limits /
  # paid_plan?, and CreditService::PLAN_MONTHLY_CREDITS["basic_trial"].
  def setup_limits
    case plan_type
    when "free"
      setup_free_limits
    when "basic", "basic_yearly", "basic_trial", "basic_5yr"
      setup_basic_limits
    when "pro", "pro_yearly", "pro_5yr"
      setup_pro_limits
    when "partner_pro"
      setup_partner_pro_plan
    when "clinician"
      setup_clinician_limits
    else
      Rails.logger.warn "Unknown plan_type #{plan_type} for user #{id}"
    end
  end

  def set_uuid
    return if self.uuid.present?
    self.uuid = SecureRandom.uuid
  end

  def locked?
    locked == true
  end

  def timezone
    self.settings["timezone"] || "America/New_York"
  end

  # Communicator slot math:
  #
  #   paid_communicator_limit — total owned `loaner` + `active` slots.
  #                             Free has 1, CLAIM/HAND-OFF ONLY — a Free user
  #                             never self-creates into it (self-creates are
  #                             always no-login sandboxes; see
  #                             Permissions::CommunicatorLimits.self_create_status).
  #   demo_communicator_limit — sandbox (no-login, board-capped) slots.
  #
  # `Permissions::CommunicatorLimits.self_create_allowed?` returns true
  # whenever the user has any non-zero slot limit (i.e. has at least one
  # slot to spend).
  # NOTE: AI usage is gated by the weighted credit ledger (CreditService), not
  # by a per-plan monthly action count. The old "ai_monthly_limit" key was dead
  # (never read on the enforcement path) and was removed — do not re-add it here.
  # Board limits match the canonical pricing table (marketing/pricing-structure.md):
  # Free 1 / Basic 100 / Pro 300.
  # --- Email verification ---------------------------------------------------
  #
  # `email_verified_at` is the single source of truth for "the address
  # currently on this account is proven reachable". It is set ONLY by paths
  # where the user clicked a link that was delivered to their inbox: the
  # signup verification link, temp-login, and confirming a pending
  # email-change link. `set_password` / invitation-accept does NOT verify —
  # email_signup hands out that session with no email opened, so reaching
  # set_password proves nothing about inbox ownership. See the task-7r brief.
  #
  # Deliberately NOT `confirmed_at` and NOT devise's :confirmable — this is a
  # JSON API on JWT, and confirmable would contend with the hand-rolled
  # email-change flow for `confirmation_token`/`confirmed_at`.
  # `devise_invitable` also stamps `confirmed_at` on `accept_invitation!` for
  # any model carrying that column, whether or not :confirmable is enabled,
  # which is exactly the shared-column bypass `email_verified_at` exists to
  # avoid. See drafts/2026-07-26-email-verification-design.md.
  EMAIL_VERIFICATION_VALIDITY = 7.days
  EMAIL_VERIFICATION_RESEND_INTERVAL = 5.minutes

  # Legacy per-image `tokens` handed to every new account (still spent by
  # API::ImagesController#find_or_create). Not AI credits — those are the
  # CreditService ledger.
  WELCOME_TOKENS = 10

  FREE_PLAN_LIMITS = {
    "plan_type" => "free",
    "board_limit" => ENV.fetch("FREE_BOARD_LIMIT", 1).to_i,
    "paid_communicator_limit" => ENV.fetch("FREE_PAID_COMMUNICATOR_LIMIT", 1).to_i,
    "demo_communicator_limit" => ENV.fetch("FREE_DEMO_COMMUNICATOR_LIMIT", 1).to_i,
  }.freeze
  BASIC_PLAN_LIMITS = {
    "plan_type" => "basic",
    "board_limit" => ENV.fetch("BASIC_BOARD_LIMIT", 100).to_i,
    "paid_communicator_limit" => ENV.fetch("BASIC_PAID_COMMUNICATOR_LIMIT", 2).to_i,
    "demo_communicator_limit" => ENV.fetch("BASIC_DEMO_COMMUNICATOR_LIMIT", 0).to_i,
  }.freeze
  PRO_PLAN_LIMITS = {
    "plan_type" => "pro",
    "board_limit" => ENV.fetch("PRO_BOARD_LIMIT", 300).to_i,
    "paid_communicator_limit" => ENV.fetch("PRO_PAID_COMMUNICATOR_LIMIT", 5).to_i,
    "demo_communicator_limit" => ENV.fetch("PRO_DEMO_COMMUNICATOR_LIMIT", 10).to_i,
  }.freeze

  # SpeakAnyWay for Clinicians — a free, manually-approved plan for verified
  # SLPs/OTs/AT specialists. **Basic-shaped limits** (100 boards / 25 groups, not
  # Pro's 300/50), with premium features unlocked and a small loaner cap. The free
  # Clinician account is for evaluating the product and seeding 2 families; a
  # working caseload is what Pro ($20) and the school license sell — so Pro-only
  # tools (caseload dashboard, bulk export) stay Pro-only. Clinician is NOT Pro —
  # never fold it into pro?; these limits are the product. ENV-overridable like
  # the other tiers. (Limits revised 2026-07-15.)
  CLINICIAN_PLAN_LIMITS = {
    "plan_type" => "clinician",
    "board_limit" => ENV.fetch("CLINICIAN_BOARD_LIMIT", 100).to_i,
    "paid_communicator_limit" => ENV.fetch("CLINICIAN_PAID_COMMUNICATOR_LIMIT", 2).to_i,
    "demo_communicator_limit" => ENV.fetch("CLINICIAN_DEMO_COMMUNICATOR_LIMIT", 2).to_i,
  }.freeze

  # The one plan_type -> limits lookup. Three hand-rolled copies of this case
  # statement used to exist (setup_limits, the old board_group_limit, and
  # beta_audit.rake's entitlement_for) and they disagreed: two omitted the
  # 5-year license types, and the audit one omitted Clinician entirely, so it
  # measured Clinician users against the FREE entitlement. An unknown or blank
  # plan_type resolves to FREE — the safe direction, and what the old
  # board_group_limit else-branch already did.
  PLAN_LIMITS_BY_TYPE = {
    "free" => FREE_PLAN_LIMITS,
    "basic" => BASIC_PLAN_LIMITS,
    "basic_yearly" => BASIC_PLAN_LIMITS,
    "basic_trial" => BASIC_PLAN_LIMITS,
    "basic_5yr" => BASIC_PLAN_LIMITS,
    "pro" => PRO_PLAN_LIMITS,
    "pro_yearly" => PRO_PLAN_LIMITS,
    "pro_5yr" => PRO_PLAN_LIMITS,
    "partner_pro" => PRO_PLAN_LIMITS,
    "clinician" => CLINICIAN_PLAN_LIMITS,
  }.freeze

  def self.plan_limits_for(plan_type)
    PLAN_LIMITS_BY_TYPE.fetch(plan_type.to_s, FREE_PLAN_LIMITS)
  end

  # Length of the Partner Program pilot. Signup creates a real Stripe no-card
  # trial of this length; extend a pilot by moving the subscription's
  # `trial_end` (rake partners:extend), which the reverse-trial webhooks honor.
  PARTNER_PILOT_TRIAL_MONTHS = ENV.fetch("PARTNER_PILOT_TRIAL_MONTHS", 3).to_i

  # Subscription statuses from which a stored subscription can never be revived
  # — the id is dead weight and the right move is to create a fresh one.
  DEAD_SUBSCRIPTION_STATUSES = %w[canceled incomplete_expired].freeze

  # Stripe rejects a `trial_end` in the past, and a user being upgraded to
  # Partner can easily carry a stale `plan_expires_at` (a lapsed pilot, an
  # expired 5-yr license). Anything this close to now is treated as stale and
  # replaced with a full pilot rather than 400ing the whole Stripe call.
  PARTNER_PILOT_MIN_TRIAL_WINDOW = 1.day

  # The pilot end date to use, given whatever the caller had on hand. Callers
  # must run their local `plan_expires_at` through this too — clamping only
  # inside the Stripe call would drift the local date from the Stripe one.
  def self.partner_pro_trial_end(candidate)
    full_pilot = Time.current + PARTNER_PILOT_TRIAL_MONTHS.months
    return full_pilot if candidate.blank?

    candidate = candidate.to_time
    candidate <= Time.current + PARTNER_PILOT_MIN_TRIAL_WINDOW ? full_pilot : candidate
  rescue StandardError
    full_pilot
  end

  def setup_partner_pro_plan
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = PRO_PLAN_LIMITS["paid_communicator_limit"]
    self.settings["demo_communicator_limit"] = PRO_PLAN_LIMITS["demo_communicator_limit"]
  end

  def setup_pro_limits
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = PRO_PLAN_LIMITS["paid_communicator_limit"]
    self.settings["demo_communicator_limit"] = PRO_PLAN_LIMITS["demo_communicator_limit"]
  end

  def setup_clinician_limits
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = CLINICIAN_PLAN_LIMITS["paid_communicator_limit"]
    self.settings["demo_communicator_limit"] = CLINICIAN_PLAN_LIMITS["demo_communicator_limit"]
  end

  def setup_basic_limits
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = BASIC_PLAN_LIMITS["paid_communicator_limit"]
    self.settings["demo_communicator_limit"] = BASIC_PLAN_LIMITS["demo_communicator_limit"]
  end

  def setup_free_limits
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = FREE_PLAN_LIMITS["paid_communicator_limit"]
    self.settings["demo_communicator_limit"] = FREE_PLAN_LIMITS["demo_communicator_limit"]
  end

  def communicator_limit=(value)
    self.settings ||= {}
    self.settings["paid_communicator_limit"] = value
    save
  end

  def demo_communicator_limit=(value)
    self.settings ||= {}
    self.settings["demo_communicator_limit"] = value
    save
  end

  def messages
    Message.where("sender_id = ? OR recipient_id = ?", id, id)
  end

  def sent_messages
    Message.where(sender_id: id, sender_deleted_at: nil)
  end

  def received_messages
    Message.where(recipient_id: id, recipient_deleted_at: nil)
  end

  def has_available_communicator?
    true # TODO: Implement logic to check if the user has available communicators
  end

  def self.create_from_email(email, stripe_customer_id = nil, inviting_user_id = nil, slug = nil)
    begin
      user = User.find_by(email: email)
      user = User.invite!(email: email, skip_invitation: true) unless user
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.error("Error creating user from email: #{email} - #{e.message}")

      user = User.find_by(stripe_customer_id: stripe_customer_id) if stripe_customer_id
      if user.nil?
        user = User.find_by(email: email)
      end
    rescue => e
      Rails.logger.error("Unexpected error creating user from email: #{email} - #{e.message}")
    end
    Rails.logger.error("FAILED while creating user from email: #{email}, inviting_user_id: #{inviting_user_id}, slug: #{slug}, stripe_customer_id: #{stripe_customer_id} errors: #{user.errors.full_messages.join(", ")}") if user && user.errors.any?
    user.ensure_settings
    user.role = "user" unless user.role
    user.plan_type ||= "free"
    user.plan_status ||= "active"
    user.settings ||= {}
    user.settings["plan_nickname"] = user.plan_type
    user.settings["slug"] = slug if slug

    if user
      if inviting_user_id
        Rails.logger.info("Creating user from invitation with inviting_user_id: #{inviting_user_id}")
        create_from_invitation(email, inviting_user_id)
      else
        user.record_signup_context!(method: slug ? "myspeak" : "email_import")
        user.notify_admin_of_signup!
        user.send_welcome_email if user.should_send_welcome_email?
        stripe_customer_id ||= user.stripe_customer_id
        if stripe_customer_id.nil?
          stripe_customer_id = User.create_stripe_customer(email)
        end
        user.stripe_customer_id = stripe_customer_id
        user.save
      end
    else
      Rails.logger.error("User not created: #{email}")
    end
    user
  end

  def self.create_from_invitation(email, invited_by_id)
    user = User.invite!(email: email, skip_invitation: true)
    if user
      user.invited_by_id = invited_by_id
      user.invited_by_type = "User"
      user.send_welcome_invitation_email(invited_by_id)
      user.save
      stripe_customer_id = User.create_stripe_customer(email)
      user.stripe_customer_id = stripe_customer_id
      user.save
      Rails.logger.info("User created from invitation: #{email}")
    else
      Rails.logger.error("User not created from invitation: #{email}")
    end
    user
  end

  def recently_used_boards
    recent_word_events = word_events.where("created_at >= ?", 1.week.ago)
    board_ids = recent_word_events.pluck(:board_id).uniq
    boards.main_boards.where(id: board_ids).limit(10)
  end

  # The single per-plan board creation cap. Resolves from `plan_type` at READ
  # time: the value used to be stamped into settings by the plan setters, so
  # every user who had ever changed plans carried a frozen copy and changing a
  # constant (or an ENV override) reached nobody. `settings["board_limit"]` now
  # means one thing only — a deliberate admin override — and is coerced because
  # the admin JSON path can store a String, which would otherwise make
  # `countable_board_count >= board_limit` raise.
  def board_limit
    override = (settings || {})["board_limit"]
    return override.to_i if override.present?

    self.class.plan_limits_for(plan_type)["board_limit"]
  end

  def comm_account_limit
    base = (settings["paid_communicator_limit"] || FREE_PLAN_LIMITS["paid_communicator_limit"]).to_i
    base + extra_communicator_slots
  end

  # Pro-only add-on slots purchased on top of the plan's base communicator limit,
  # stored in settings["extra_communicator_slots"]. See Billing::ExtraCommunicators.
  def extra_communicator_slots
    ((settings || {})["extra_communicator_slots"] || 0).to_i
  end

  # Set the purchased extra-communicator count (clamped to the allowed range),
  # then reconcile fallback so newly-affordable slots restore any communicators
  # that had dropped into fallback mode. No-op when the count is unchanged, so
  # it's cheap to call on every subscription webhook. Pro-gating is the caller's
  # job (the webhook / endpoint pass 0 for non-Pro plans).
  def apply_extra_communicator_slots!(count)
    clamped = Billing::ExtraCommunicators.clamp(count)
    self.settings ||= {}
    return if settings["extra_communicator_slots"].to_i == clamped

    settings["extra_communicator_slots"] = clamped
    save!
    reconcile_communicator_fallback!
  end

  # Every signed-in user needs at least one communicator slot — otherwise
  # the MySpeak wizard 403s on `Permissions::CommunicatorLimits.can_create?`
  # ("Your plan does not include communicator accounts."). Older free
  # accounts predate FREE_PLAN_LIMITS and have an explicit 0; new users
  # whose settings haven't been initialized read as nil → 0 too. Bump to
  # the free-plan default when below it; never lower an existing higher
  # value.
  def ensure_minimum_communicator_slot!
    minimum = FREE_PLAN_LIMITS["paid_communicator_limit"]
    self.settings ||= {}
    current = settings["paid_communicator_limit"].to_i
    return if current >= minimum
    settings["paid_communicator_limit"] = minimum
    save
  end

  def get_stripe_subscriptions
    begin
      subscriptions = Stripe::Subscription.list({ customer: stripe_customer_id })
      subscriptions.each do |subscription|
        puts "Subscription ID: #{subscription.inspect}"
        puts "-----------------------------"
      end
    rescue Stripe::StripeError => e
      Rails.logger.error "Error retrieving subscriptions: #{e.message}"
    end
    subscriptions
  end

  # `swap_existing:` is passed through to sync_partner_pro_subscription! —
  # false (signup: create only) or true (admin upgrade: move an existing
  # subscription onto the partner price). Returns that Stripe result hash so an
  # admin caller can report what actually happened in Stripe.
  def self.handle_new_partner_pro_subscription(user, plan_nickname = "partner_pro", swap_existing: false)
    Rails.logger.info "Handling Partner Pro subscription for user: #{user.email} with plan_nickname: #{plan_nickname}"
    user.role = "partner"
    user.plan_status = "active"
    # Clamped HERE, not just inside the Stripe call: the next line writes the
    # local plan_expires_at, and the two dates must not drift.
    trial_end = partner_pro_trial_end(user.plan_expires_at)
    user.plan_expires_at = trial_end
    partner_group = user.get_partner_group
    user.settings["partner_group"] = partner_group
    # Partners get PartnerMailer.welcome_email at signup, so mark the generic
    # plan welcome as already sent — otherwise the Stripe subscription webhook
    # (send_plan_welcome_email_once!) would send a second, Pro-branded welcome
    # when the trial subscription lands as `trialing`.
    already_welcomed = Array(user.settings["plan_welcome_sent_for"])
    user.settings["plan_welcome_sent_for"] = (already_welcomed + ["partner_pro"]).uniq
    user.save

    # Phase 2: create a real no-card Stripe trial subscription so the pilot
    # rides the reverse-trial machinery (#264) — auto-expiry to Free at trial
    # end, the `trial_will_end` reminder, and one-click conversion. Fail-soft:
    # if Stripe is unreachable the partner is still fully provisioned by the
    # local grant below, and the subscription can be backfilled later.
    stripe_result = user.sync_partner_pro_subscription!(trial_end: trial_end, swap_existing: swap_existing)

    # Grant the Partner Pro (Pro-equivalent) credit allowance IMMEDIATELY.
    # The initial free-tier grant is now deferred to email verification (see
    # User#mark_email_verified!), so unlike before, ensure_initial_grant!
    # hasn't necessarily run yet at this point. Either way, this explicit call
    # is what actually provisions a partner right away — without it a partner
    # would otherwise wait on email verification (or a free allowance, if
    # already verified) instead of getting the partner_pro amount now.
    # grant_plan! resets the plan balance to the partner_pro monthly amount now.
    begin
      CreditService.grant_plan!(
        user,
        amount: CreditService.monthly_credits_for("partner_pro"),
        period_end: CreditService.initial_period_end_for("partner_pro"),
        metadata: { source: "partner_pro_signup", plan_type: "partner_pro" },
      )
    rescue => e
      Rails.logger.error "Partner Pro credit grant failed for #{user&.email}: #{e.message}"
    end

    begin
      # "Partner Program" is the stable trigger tag the Partner Mailchimp
      # Customer Journey fires on; the monthly PartnerPro_<Month> cohort tag
      # stays for per-cohort reporting. Pass the User object + tags: keyword —
      # record_new_subscriber reads user.email/first_name/etc, not a String.
      partner_tags = ["Partner Program", partner_group]
      Rails.logger.info "Recording new subscriber for Mailchimp: #{user.email} with tags: #{partner_tags}"
      MailchimpService.new.record_new_subscriber(user, tags: partner_tags)
    rescue => e
      Rails.logger.error "Mailchimp tag update failed for pilot_partner: #{e.message}"
    end

    # Last expression on purpose: the Stripe outcome is what the admin flash
    # reports. The credit and Mailchimp blocks above keep their own rescues so
    # a Mailchimp hiccup can't clobber a successful Stripe result.
    stripe_result
  rescue StandardError => e
    Rails.logger.error "Error handling Partner Pro subscription for user #{user&.email}: #{e.inspect}"
    { ok: false, action: :failed, error: "#{e.class}: #{e.message}" }
  end

  def opening_board
    opening_board_id = settings["opening_board_id"]
    return nil unless opening_board_id
    if opening_board_id && opening_board_id.is_a?(Hash)
      opening_board_id = opening_board_id["id"]
    end
    if opening_board_id.nil?
      Rails.logger.warn "User #{id} has no opening_board_id in settings"
      return nil
    end
    Board.find_by(id: opening_board_id&.to_i)
  end

  def unassign_vendor
    return unless vendor_id
    Rails.logger.info "Unassigning vendor for user #{id} with vendor_id #{vendor_id}"
    vendor = Vendor.find_by(user_id: id, id: vendor_id)
    if vendor
      Rails.logger.info "Found vendor #{vendor.business_name} for user #{id}, unassigning..."
      vendor.user_id = nil
      vendor.save
      self.vendor_id = nil
      self.save
    else
      Rails.logger.warn "No vendor found for user #{id} with vendor_id #{vendor_id}"
    end
  end

  def delete_stripe_customer
    return unless stripe_customer_id
    return if Rails.env.production? && !ENV["STRIPE_DELETE_CUSTOMERS"]
    begin
      result = Stripe::Customer.delete(stripe_customer_id)
    rescue StandardError => e
      Rails.logger.error "Error deleting Stripe customer: #{e.message}"
      return
    end
    Rails.logger.info "Deleted stripe customer: #{result}" if result["deleted"]
  end

  def self.create_stripe_customer(email)
    result = Stripe::Customer.create({ email: email })
    # free_plan_id = ENV["STRIPE_FREE_PLAN_ID"] || "price_1QrmMGGfsUBE8bl39Anm4Pyg"
    # Stripe::Subscription.create({
    #   customer: result["id"],
    #   items: [{ price: free_plan_id }],
    # })
    result["id"]
  end

  # Lazily create the Stripe customer on first billing touch. Mobile signups
  # and legacy accounts have no customer until they hit checkout or the
  # billing portal.
  #
  # A stored id is verified, not trusted: if the customer was deleted in the
  # Stripe dashboard (or the row predates an account/key change) every billing
  # call 400s on "No such customer" with no way out — the user is permanently
  # unable to upgrade. Re-create in that case so the path self-heals.
  def ensure_stripe_customer!
    return stripe_customer_id if stripe_customer_id.present? && stripe_customer_live?
    update!(stripe_customer_id: User.create_stripe_customer(email))
    stripe_customer_id
  end

  # True when `stripe_customer_id` resolves to a real, non-deleted customer on
  # the current Stripe key.
  #
  # Fails OPEN: only Stripe telling us the customer is gone (`resource_missing`
  # / `deleted`) invalidates the id. A network blip, auth error, or outage
  # returns true so we keep the stored id — dropping it would orphan the
  # account from its subscription and billing history.
  def stripe_customer_live?
    customer = Stripe::Customer.retrieve(stripe_customer_id)
    return true unless customer.respond_to?(:deleted) && customer.deleted

    Rails.logger.warn "[Billing] stripe customer #{stripe_customer_id} is deleted for user=#{id}; recreating"
    false
  rescue Stripe::InvalidRequestError => e
    if e.code.to_s == "resource_missing"
      Rails.logger.warn "[Billing] stripe customer #{stripe_customer_id} missing for user=#{id}; recreating"
      return false
    end
    raise
  rescue Stripe::StripeError => e
    # Transient/unrelated Stripe failure — keep the id and let the caller's own
    # error handling deal with whatever happens next.
    Rails.logger.error "[Billing] could not verify stripe customer for user=#{id}: #{e.class} - #{e.message}"
    true
  end

  # Put this user's Stripe subscription on the Partner Pro price, so STRIPE is
  # what asserts `partner_pro` and the subscription webhook preserves it.
  #
  # The pilot rides the reverse-trial machinery (#264): `trialing` now, a
  # `trial_will_end` reminder ~3 days out, and — if no card is ever added — a
  # clean cancel → `customer.subscription.deleted` → the Clinician landing at
  # trial end (content retained). The Partner Pro price carries
  # `metadata.plan_type=partner_pro`, which is what keeps the webhook from
  # writing some other plan back over the user on the next routine update.
  #
  # `swap_existing:` is the whole difference between the two callers. Signup
  # has no subscription, so it only ever creates (false). An ADMIN upgrading an
  # existing customer does have one, sitting on a basic/pro price whose
  # metadata will silently revert them — so the admin path moves that
  # subscription onto the partner price (true) instead of leaving it to lie.
  #
  # Fail-soft: never raises, so a partner signup can't 500 on a Stripe blip and
  # the caller's local grant still provisions them. The RESULT is what makes a
  # failure loud — an admin needs to know Stripe didn't land.
  #
  # Returns { ok:, action:, subscription:, subscription_id:, price_id:,
  #           trial_end:, previous_price_id:, previous_interval:,
  #           previous_amount:, previous_status:, error: }
  # action ∈ :created | :swapped | :already_on_price | :reused | :skipped | :failed
  def sync_partner_pro_subscription!(trial_end:, swap_existing: false)
    price_id = Billing::PartnerProStatus.partner_price_id
    if price_id.blank?
      Rails.logger.error "[PartnerPilot] STRIPE_PRICE_PARTNER_PRO unset; skipping Stripe subscription for user=#{id}"
      return { ok: false, action: :skipped, error: "STRIPE_PRICE_PARTNER_PRO is not configured" }
    end

    # Defensive re-clamp for direct callers; handle_new_partner_pro_subscription
    # clamps first so the local plan_expires_at matches what Stripe is told.
    trial_end = User.partner_pro_trial_end(trial_end)

    if stripe_subscription_id.present?
      # Signup semantics: a subscription already exists, leave it alone.
      unless swap_existing
        return { ok: true, action: :reused, subscription_id: stripe_subscription_id }
      end

      existing = live_subscription_for_swap(stripe_subscription_id)
      if existing
        return swap_primary_item_to!(existing, price_id, trial_end)
      end

      # Gone from Stripe, or terminally dead. Drop the stale id and create fresh.
      update_columns(stripe_subscription_id: nil)
    end

    ensure_stripe_customer!

    subscription = Stripe::Subscription.create(
      customer: stripe_customer_id,
      items: [{ price: price_id }],
      trial_end: trial_end.to_i,
      # No card up front; if the trial ends with none on file, cancel cleanly
      # instead of cutting an unpayable invoice (mirrors the #264 reverse trial).
      trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
      metadata: { user_id: id, plan_key: "partner_pro", source: "partner_pilot_signup" },
    )
    update_columns(stripe_subscription_id: subscription.id) if subscription.id.present?
    Rails.logger.info "[PartnerPilot] created trial subscription #{subscription.id} for user=#{id} trial_end=#{trial_end}"
    {
      ok: true, action: :created, subscription: subscription,
      subscription_id: subscription.id, price_id: price_id, trial_end: trial_end,
    }
  rescue => e
    Rails.logger.error "[PartnerPilot] failed to sync trial subscription for user=#{id}: #{e.class} - #{e.message}"
    { ok: false, action: :failed, error: "#{e.class}: #{e.message}" }
  end

  # Backwards-compatible signup entry point: ensure a Partner Pro trial
  # subscription exists, never touching one that already does. Kept as a thin
  # wrapper (rather than folding a kwarg into it) so the public signup path's
  # return values stay exactly what they were.
  def ensure_partner_pro_trial_subscription!(trial_end:)
    result = sync_partner_pro_subscription!(trial_end: trial_end, swap_existing: false)
    case result[:action]
    when :reused then stripe_subscription_id
    when :created then result[:subscription]
    end
  end

  private

  # The live subscription behind a stored id, or nil when that id is dead and
  # the caller should create a fresh subscription instead.
  #
  # Mirrors stripe_customer_live?: only Stripe telling us it's gone (or a
  # terminal status) invalidates the id. Every other error RAISES, on purpose —
  # falling through to create on an unknown failure would leave the original
  # subscription live and bill the user twice.
  def live_subscription_for_swap(sub_id)
    subscription = Stripe::Subscription.retrieve(sub_id)
    if DEAD_SUBSCRIPTION_STATUSES.include?(subscription.status.to_s)
      Rails.logger.warn "[PartnerPilot] subscription #{sub_id} is #{subscription.status} for user=#{id}; will create a new one"
      return nil
    end

    subscription
  rescue Stripe::InvalidRequestError => e
    if e.code.to_s == "resource_missing"
      Rails.logger.warn "[PartnerPilot] subscription #{sub_id} missing for user=#{id}; will create a new one"
      return nil
    end

    raise
  end

  # Move an existing subscription's PLAN item onto the Partner Pro price.
  #
  # Every argument here is load-bearing:
  #   - only the plan item is listed, so extra-communicator add-on items are
  #     left untouched by Stripe (they stay valid: partners satisfy `pro?`,
  #     which is what the webhook re-derives the slot count from).
  #   - `quantity` is explicit because Stripe silently resets it to 1 on a
  #     price change.
  #   - `trial_end` on an active subscription is supported and moves the
  #     billing anchor itself, so no billing_cycle_anchor; `proration_behavior:
  #     "none"` is its documented pairing and is what stops an immediate
  #     invoice or credit being cut.
  #   - `cancel_at_period_end: false` because a pending cancel would both kill
  #     the subscription and drag `trial_end` back to the cancel date.
  def swap_primary_item_to!(subscription, price_id, trial_end)
    item = Billing::PartnerProStatus.plan_item(subscription)
    raise "subscription #{subscription.id} has no plan item to swap" if item.nil?

    previous = {
      previous_price_id: item.price&.id,
      previous_interval: Billing::PartnerProStatus.interval_for(item.price),
      previous_amount: Billing::PartnerProStatus.amount_for(item.price),
      previous_status: subscription.status,
    }

    if item.price&.id == price_id && !subscription.try(:cancel_at_period_end)
      Rails.logger.info "[PartnerPilot] subscription #{subscription.id} already on the Partner Pro price for user=#{id}"
      return {
        ok: true, action: :already_on_price, subscription: subscription,
        subscription_id: subscription.id, price_id: price_id, trial_end: trial_end,
      }.merge(previous)
    end

    updated = Stripe::Subscription.update(
      subscription.id,
      {
        items: [{ id: item.id, price: price_id, quantity: (item.try(:quantity) || 1) }],
        proration_behavior: "none",
        trial_end: trial_end.to_i,
        trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
        cancel_at_period_end: false,
        metadata: (subscription.metadata.respond_to?(:to_h) ? subscription.metadata.to_h : {}).merge(
          "user_id" => id.to_s, "plan_key" => "partner_pro", "source" => "admin_partner_pro_upgrade",
        ),
      },
    )
    update_columns(stripe_subscription_id: subscription.id) if stripe_subscription_id != subscription.id
    Rails.logger.info "[PartnerPilot] swapped subscription #{subscription.id} onto the Partner Pro price " \
                      "for user=#{id} (was #{previous[:previous_price_id]}) trial_end=#{trial_end}"
    {
      ok: true, action: :swapped, subscription: updated,
      subscription_id: subscription.id, price_id: price_id, trial_end: trial_end,
    }.merge(previous)
  end

  public

  # Extend a partner pilot: push both the local `plan_expires_at` and the Stripe
  # subscription's `trial_end` out to `new_end` so Stripe re-arms the
  # `trial_will_end` reminder and the auto-cancel. Keeps the two in sync (the
  # reverse-trial webhooks are driven by the Stripe date). Returns the updated
  # subscription, or nil if there's no Stripe subscription to move.
  def extend_partner_pro_trial!(new_end:)
    update!(plan_expires_at: new_end)

    if stripe_subscription_id.blank?
      Rails.logger.warn "[PartnerPilot] extend: user=#{id} has no stripe_subscription_id; updated plan_expires_at only"
      return nil
    end

    subscription = Stripe::Subscription.update(
      stripe_subscription_id,
      { trial_end: new_end.to_i, proration_behavior: "none" },
    )
    Rails.logger.info "[PartnerPilot] extended trial for user=#{id} sub=#{stripe_subscription_id} to #{new_end}"
    subscription
  rescue => e
    Rails.logger.error "[PartnerPilot] failed to extend trial for user=#{id}: #{e.class} - #{e.message}"
    nil
  end

  def audit_logging_disabled?
    settings.present? && settings["disable_audit_logging"] == true
  end

  def create_opening_board
    Board.create_dynamic_default_for_user(self)
  end

  # Methods for user settings
  def set_default_settings
    default_settings = ensure_settings
    voice_settings = { name: "polly:kevin", speed: 1.0, pitch: 1.0, volume: 1.0, rate: 1.0, language: "en-US" }
    default_settings["voice"] = voice_settings unless settings["voice"]
    # self.settings = { voice: voice_settings, wait_to_speak: false, disable_audit_logging: false,
    #                   enable_image_display: true, enable_text_display: true, show_labels: true, show_tutorial: true }
    self.settings = default_settings
    save
  end

  def predictive_boards
    boards.predictive.includes(:parent, :board_images).order(name: :asc)
  end

  def predictive_board_id
    settings["predictive_board_id"]
  end

  def dynamic_boards
    boards.dynamic.includes(:parent, :board_images).order(name: :asc)
  end

  def predictive_images
    images.joins(:board_images).where(board_images: { board_id: predictive_boards.select(:id) }).distinct
  end

  def add_to_settings(key, value)
    settings[key] = value
    save
  end

  # Methods for handling teams and boards
  def team_boards
    TeamBoard.where(team_id: team_users.select(:team_id))
  end

  def current_team_boards
    TeamBoard.where(team_id: current_team_id)
  end

  def teams
    Team.where(id: team_users.select(:team_id))
  end

  def shared_with_me_boards
    Board.with_artifacts.where(id: team_boards.select(:board_id))
  end

  def email_verified?
    email_verified_at.present?
  end

  # Issues a fresh verification token and stamps the send time. The stamp
  # drives both expiry (EMAIL_VERIFICATION_VALIDITY) and resend cooldown
  # (EMAIL_VERIFICATION_RESEND_INTERVAL). Returns the raw token.
  def generate_email_verification_token!
    token = SecureRandom.hex(16)
    update!(email_verification_token: token, email_verification_sent_at: Time.current)
    token
  end

  def email_verification_token_valid?
    email_verification_sent_at.present? &&
      email_verification_sent_at > EMAIL_VERIFICATION_VALIDITY.ago
  end

  def can_resend_email_verification?
    email_verification_sent_at.blank? ||
      email_verification_sent_at < EMAIL_VERIFICATION_RESEND_INTERVAL.ago
  end

  # Persists a token value the caller already handed to the mailer (see
  # API::UsersController#resend_email_verification), rather than minting one
  # itself like generate_email_verification_token! does. Used so the resend
  # flow can enqueue the email with a token before committing anything, and
  # only start the resend cooldown once the enqueue has actually succeeded.
  def persist_email_verification_token!(token)
    update!(email_verification_token: token, email_verification_sent_at: Time.current)
  end

  # The ONE place an account becomes verified. Idempotent, so every path that
  # proves inbox ownership — the signup verification link
  # (GET /api/verify_email), temp-login, and confirm_email_change (confirming
  # a pending email-change link) — can call it freely without risking a
  # double token grant. `set_password` / invitation-accept must NOT call this:
  # see the in-body note below for why.
  #
  # The grants below are idempotent no-ops for any account created since
  # grant_signup_ai_allowance started running at signup. They stay so that an
  # account created BEFORE that change — which was left at zero tokens and
  # zero credits by the old gate — is healed the first time it verifies.
  #
  # Returns true if this call newly verified the account, false if it was
  # already verified.
  # `with_lock` wraps the block in `lock!` + a transaction, and `lock!` raises
  # a plain `RuntimeError` ("Locking a record with unpersisted changes is not
  # supported") if the record already has unsaved changes — unlike the old
  # `transaction do ... update! ... end` this replaced, which tolerated a
  # dirty object. Callers must pass a clean (unmutated) user in.
  def mark_email_verified!
    return false if email_verified?

    with_lock do
      # Re-check under the row lock: a scanner prefetch racing the user's own
      # click can put two requests past the guard above. The balance is safe
      # either way, but callers branch on the return value to pick user-facing
      # copy, so only one call may report true.
      return false if email_verified?

      # The verification token is deliberately NOT cleared here — see
      # verify_email in API::UsersController. Email security scanners prefetch
      # links and users double-click; keeping the token lets a replay resolve
      # to this user and get "already confirmed" instead of "invalid link". It
      # grants nothing once email_verified_at is set, and expires after 7 days.
      #
      # Writes email_verified_at, NOT confirmed_at, deliberately.
      # devise_invitable stamps confirmed_at on accept_invitation! for any
      # model carrying that column (devise_invitable/models.rb:98) — a bare
      # set_password call (no inbox access, just the session email_signup
      # already handed out) would otherwise confer verified status with zero
      # proof of inbox ownership. See the task-7r brief. A future reader must
      # NOT "simplify" this back onto confirmed_at.
      update!(email_verified_at: Time.current)

      # `tokens` is the legacy field (still spent by
      # images_controller#find_or_create). Idempotent on its own stamp, so an
      # account that already got its signup grant is untouched here.
      grant_welcome_tokens!
    end

    # AI credits are granted OUTSIDE the lock/transaction, deliberately.
    # ensure_initial_grant! rescues its own errors and returns nil, but
    # grant_plan! runs inside a nested ActiveRecord transaction that would
    # join this one if called above — a DB error there marks the outer
    # transaction aborted, the rescue swallows it, and the COMMIT silently
    # becomes a ROLLBACK, undoing email_verified_at and the token grant too.
    # Sitting here, a credit-grant failure can never take verification down
    # with it. Safe to call unconditionally: ensure_initial_grant! is
    # idempotent (no-ops once a plan_grant exists), which since the signup
    # grant landed is the normal case.
    grant_initial_plan_credits
    true
  end

  # Token management
  # Idempotent on `settings["welcome_tokens_granted_at"]`. Signup is the
  # normal grant point (grant_signup_ai_allowance); mark_email_verified! calls
  # it too, which is what heals an account created while the initial grant was
  # still gated on verification. Returns true only when it actually granted.
  def grant_welcome_tokens!
    current = settings || {}
    return false if current["welcome_tokens_granted_at"].present?

    # Non-bang `update`, like the add_tokens call this replaced: a failure here
    # must not raise out of mark_email_verified!'s with_lock and roll the
    # verification back. Nothing is stamped unless the write lands, so a failed
    # grant is simply retried the next time this runs.
    update(
      tokens: tokens.to_i + WELCOME_TOKENS,
      settings: current.merge("welcome_tokens_granted_at" => Time.current.iso8601),
    )
  end

  def add_tokens(amount)
    update(tokens: tokens + amount)
  end

  def remove_tokens(amount)
    update(tokens: tokens - amount)
  end

  # Authorization and access control methods
  def admin?
    role == "admin"
  end

  def demo?
    play_demo == true
  end

  def can_edit?(model)
    return false unless model
    return true if admin?
    return false if model.respond_to?(:predefined) && model.predefined
    model&.user_id == id
  end

  def can_view_account?(account_id)
    return false unless account_id
    account = ChildAccount.find_by(id: account_id)
    return false unless account
    return true if account.user_id == id
    return true if admin?
    account.team_users.where(user_id: id, role: TeamUser::ROLES).exists?
  end

  def can_edit_profile?(profile_id, profileable_type = "User")
    return false unless profile_id
    return true if admin?
    account_profile = Profile.find_by(id: profile_id.to_i, profileable_type: "User")

    if account_profile && account_profile.profileable_id == id
      return true
    end
    comm_profile = Profile.find_by(id: profile_id.to_i, profileable_type: "ChildAccount")
    comm_account = ChildAccount.find_by(id: comm_profile.profileable_id) if comm_profile
    teams = comm_account.teams if comm_account
    if teams && teams.any? { |team| team.team_users.where(user_id: id, role: "admin").exists? }
      return true
    end
    false
  end

  # Can the user curate boards on the communicator? Issue #216 — only
  # admin (account owner) and supervisor (SLP power-collaborator) can
  # assign/reorder/favorite boards on the communicator. `member` is
  # read-only on the communicator; they can add boards to the team
  # library but cannot push them onto the communicator.
  CURATE_ROLES = %w[admin supervisor].freeze

  def can_add_boards_to_account?(account_ids)
    return false unless account_ids
    account_id = account_ids.first

    account = ChildAccount.includes(teams: :team_users).find_by(id: account_id)
    return false unless account
    return true if account.user_id == id
    return true if admin?
    account.team_users.where(user_id: id, role: CURATE_ROLES).exists?
  end

  def can_favorite?(model)
    return false unless model
    return true if admin? || !model.user_id || model.user_id == DEFAULT_ADMIN_ID
    model&.user_id == id
  end

  # Document-related methods
  def favorite_docs
    Doc.with_attached_image.joins(:user_docs).where(user_docs: { user_id: id })
  end

  def display_docs_for_image(image_id)
    ActiveRecord::Base.logger.silence do
      docs = Doc.joins(:user_docs)
        .where(user_docs: { user_id: id, image_id: image_id })
        .all
      return docs if docs.present?
      Doc.joins(:user_docs)
         .where(user_docs: { user_id: [nil, DEFAULT_ADMIN_ID], image_id: image_id })
         .all
    end
  end

  def voice_settings
    settings["voice"] = { name: "polly:kevin", speed: 1, pitch: 1, volume: 1, rate: 1, language: "en-US" } unless settings["voice"]
    settings["voice"]
  end

  def voice
    voice_settings["name"]
  end

  def voice_speed
    voice_settings["speed"]
  end

  def language
    voice_settings["language"] || "en-US"
  end

  include LocaleResolution

  def is_a_favorite?(doc)
    favorite_docs.include?(doc)
  end

  # Helper methods
  def display_name
    return email.split("@").first if name.blank?
    name
  end

  def first_name
    return email.split("@").first if name.blank?
    name.split(" ").first
  end

  def last_name
    return "" if name.blank?
    name.split(" ").last
  end

  def self.default_admin
    admin.find(DEFAULT_ADMIN_ID)
  end

  def self.valid_credentials?(email, password)
    user = find_by(email: email)
    user&.valid_password?(password) ? user : nil
  end

  def invite_to_team!(team, inviter, role = "member")
    BaseMailer.team_invitation_email(self, inviter, team, role).deliver_later
    if stripe_customer_id.nil?
      stripe_customer_id = User.create_stripe_customer(email)
      update!(stripe_customer_id: stripe_customer_id)
    end
    self
  end

  def self.invite_new_user_to_team!(new_user_email, inviter, team, role)
    @user = User.find_by(email: new_user_email)
    unless @user
      @user = User.invite!(email: new_user_email) do |u|
        u.skip_invitation = true
      end
    end
    BaseMailer.team_invitation_email(@user, inviter, team, role).deliver_later
    if @user.stripe_customer_id.nil?
      stripe_customer_id = User.create_stripe_customer(new_user_email)
      @user.update!(stripe_customer_id: stripe_customer_id)
    end
    @user
  end

  def send_partner_welcome_email
    Rails.logger.info "Sending partner welcome email to #{email}"
    begin
      PartnerMailer.welcome_email(self).deliver_later
      Rails.logger.info "Partner welcome email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending partner welcome email: #{e.message}")
    end
  end

  def send_temp_login_email
    Rails.logger.info "Sending temporary login email to #{email}"
    begin
      TempLoginService.issue_for!(self)
      UserMailer.temporary_login_email(self, User::TEMP_LOGIN_TOKEN_EXPIRY_HOURS).deliver_later
      Rails.logger.info "Temporary login email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending temporary login email: #{e.message}")
    end
  end

  # Records how and where this account was created so the admin signup alert
  # can report it. Stored in `settings` rather than columns: nothing queries
  # it, so a jsonb key avoids a migration and a backfill decision. Accounts
  # created before this shipped have neither key and render as "unknown".
  # `ref` is the creator/partner attribution from the signup link's `?ref=`
  # query param. Written only when it survives sanitizing, so an absent ref
  # leaves no key at all — "no attribution" and "attributed to blank" must not
  # be indistinguishable in the admin view.
  def record_signup_context!(platform: nil, method: nil, ref: nil)
    self.settings ||= {}
    settings["signup_platform"] = platform.presence || "web"
    settings["signup_method"] = method
    sanitized_ref = self.class.sanitize_signup_ref(ref)
    settings["signup_ref"] = sanitized_ref if sanitized_ref
    save
  end

  SIGNUP_REF_MAX_LENGTH = 64

  # Attribution refs come straight off a public query param, so they are
  # normalized (a link shared as `?ref=EmilyDiaz` must match `?ref=emilydiaz`)
  # and length-capped. Returns nil for anything blank so callers can decide
  # not to write the key.
  def self.sanitize_signup_ref(value)
    value.to_s.strip.downcase.first(SIGNUP_REF_MAX_LENGTH).presence
  end

  # Single entry point for the admin "new signup" alert. Deliberately NOT
  # called from the welcome-email methods: `send_plan_welcome_email_once!`
  # routes through `send_welcome_email`, so an upgrade used to send a "new
  # user signed up" alert, as did the admin dashboard's resend button.
  # Idempotent per account and fails soft — an admin notification must never
  # break a signup request.
  def notify_admin_of_signup!
    return if admin?
    self.settings ||= {}
    return if settings["admin_new_user_notified"]
    AdminMailer.new_user_email(self).deliver_later
    settings["admin_new_user_notified"] = true
    save
    nil
  rescue => e
    Rails.logger.error("Admin new-user notification failed for user #{id}: #{e.message}")
    nil
  end

  def send_general_welcome_email
    Rails.logger.info "Preparing to send welcome email to #{email}"
    begin
      UserMailer.welcome_email(self).deliver_later
      self.settings["welcome_email_sent"] = true
      self.save
      update_mailchimp_subscription
    rescue => e
      Rails.logger.error("Error sending general welcome email: #{e.message}")
    end
  end

  def send_welcome_email_free(raw_invitation_token = nil)
    Rails.logger.info "Sending free welcome email to #{email}"
    UserMailer.welcome_free_email(self, raw_invitation_token).deliver_later
  end

  def send_welcome_email_basic(raw_invitation_token = nil)
    Rails.logger.info "Sending basic welcome email to #{email}"
    UserMailer.welcome_basic_email(self, raw_invitation_token).deliver_later
  end

  def send_welcome_email_pro(raw_invitation_token = nil)
    Rails.logger.info "Sending pro welcome email to #{email}"
    UserMailer.welcome_pro_email(self, raw_invitation_token).deliver_later
  end

  # raw_invitation_token: pass the in-memory token from invite! so the welcome
  # email can render the /welcome/token/ magic link — the virtual attr doesn't
  # survive deliver_later's GlobalID round-trip, so it must travel as a String.
  def send_welcome_email(plan_nickname = nil, slug = nil, raw_invitation_token: nil)
    unless plan_nickname
      plan_nickname = settings["plan_nickname"] || plan_type
    end
    begin
      if plan_nickname.nil? || plan_nickname.include?("free")
        send_welcome_email_free(raw_invitation_token)
      elsif plan_nickname.include?("basic")
        send_welcome_email_basic(raw_invitation_token)
      elsif plan_nickname.include?("pro") || plan_nickname.include?("plus")
        send_welcome_email_pro(raw_invitation_token)
      else
        Rails.logger.error "Unknown plan nickname: #{plan_nickname}, sending free welcome email"
        send_welcome_email_free(raw_invitation_token)
      end
      self.settings["welcome_email_sent"] = true
      self.save
      update_mailchimp_subscription

      Rails.logger.info "Welcome email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending welcome email: #{e.message}")
    end
  end

  def send_pro_setup_email
    Rails.logger.info "Sending pro setup email to #{email}"
    begin
      SetupMailer.pro_setup_email(self).deliver_later
      Rails.logger.info "Pro setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending pro setup email: #{e.message}")
    end
  end

  def send_free_setup_email
    Rails.logger.info "Sending free setup email to #{email}"
    begin
      UserMailer.welcome_free_email(self).deliver_later
      Rails.logger.info "Free setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending free setup email: #{e.message}")
    end
  end

  def send_vendor_setup_email
    Rails.logger.info "Sending vendor setup email to #{email}"
    begin
      SetupMailer.vendor_setup_email(self).deliver_later
      Rails.logger.info "Vendor setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending vendor setup email: #{e.message}")
    end
  end

  def send_setup_email
    Rails.logger.info "Sending setup email to #{email}"
    begin
      if vendor?
        send_vendor_setup_email
      elsif pro? || plus? || premium?
        send_pro_setup_email
      elsif free?
        send_free_setup_email
      end
      Rails.logger.info "Setup email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending setup email: #{e.message}")
    end
  end

  def send_welcome_invitation_email(inviter_id)
    Rails.logger.info "Sending welcome invitation email to #{email} from user ID #{inviter_id}"
    begin
      UserMailer.welcome_invitation_email(self, inviter_id).deliver_later
      # AdminMailer.new_user_email(self).deliver_later
    rescue => e
      Rails.logger.error("Error sending welcome invitation email: #{e.message}")
    end
  end

  def send_welcome_new_vendor(vendor)
    business_name = vendor.business_name
    Rails.logger.info "Sending welcome new vendor email to #{email} for business #{business_name}"
    begin
      UserMailer.welcome_new_vendor_email(self, vendor).deliver_later
    rescue => e
      Rails.logger.error("Error sending welcome new vendor email: #{e.message}")
    end
  end

  def send_welcome_to_organization_email(inviter_id)
    Rails.logger.info "Sending welcome to organization email to #{email} from user ID #{inviter_id}"
    begin
      UserMailer.welcome_to_organization_email(self, inviter_id).deliver_later
    rescue => e
      Rails.logger.error("Error sending welcome to organization email: #{e.message}")
    end
  end

  def send_welcome_with_claim_link_email(slug)
    Rails.logger.info "Sending welcome with claim link email to #{email} with slug #{slug}"
    begin
      UserMailer.welcome_with_claim_link_email(self, slug).deliver_later
    rescue => e
      Rails.logger.error("Error sending welcome with claim link email: #{e.message}")
    end
  end

  def update_mailchimp_subscription(opts = {})
    MailchimpUpsertSubscriberJob.perform_async(self.id, opts)
  end

  def update_mailchimp_tags
    tags = []
    tags << "#{plan_type&.camelcase(:upper)}Plan" || "FreePlan"
    unless role.blank? || role == "user"
      role_tag = role.capitalize
      tags << role_tag
    end

    plan_status = self.plan_status || "active"
    tags << plan_status.capitalize

    if partner_pro?
      partner_group = get_partner_group
      tags << partner_group
    end
    puts "Updating Mailchimp tags for user #{email}: #{tags.inspect}"
    MailchimpService.new.update_subscriber_tags(email, tags, [])
  rescue => e
    Rails.logger.error "Mailchimp tag update failed: #{e.message}"
  end

  # Ruby counterpart of the demo_accounts scope — keep the two in agreement
  # (see the scope's note). Gates Mailchimp journey sends and the DEMO_USER
  # merge field.
  def demo_user?
    return true if settings.is_a?(Hash) && settings[INTERNAL_ACCOUNT_FLAG] == true

    address = email.to_s.downcase
    self.class.demo_email_patterns.any? { |pattern| address.include?(pattern.downcase) }
  end

  def mark_internal!
    update!(settings: (settings || {}).merge(INTERNAL_ACCOUNT_FLAG => true))
  end

  def unmark_internal!
    update!(settings: (settings || {}).except(INTERNAL_ACCOUNT_FLAG))
  end

  def partner_pro?
    pro? && role == "partner"
  end

  def get_partner_group
    current_month = Time.now.month
    current_month_name = Date::ABBR_MONTHNAMES[current_month]
    "PartnerPro_#{current_month_name}"
  rescue StandardError => e
    Rails.logger.error "Error determining partner group: #{e.inspect}"
    "PartnerPro_Unknown"
  end

  def record_signin_event
    mailchimp = MailchimpService.new
    mailchimp.record_signin_event(self)
  end

  def should_receive_notifications?
    return false if admin?
    return false if locked?
    return false if settings["disable_notifications"] == true
    return false if settings["disable_notifications"] == "true"
    return false if settings["disable_notifications"] == "1"
    return false if settings["disable_notifications"] == 1
    recently_notified = settings["recently_notified"]
    return false if recently_notified && recently_notified > 2.hours.ago
    true
  end

  def set_recently_notified!
    settings["recently_notified"] = Time.now
    save!
  end

  def resource_type
    "User"
  end

  # Partner Pro is a Pro-equivalent tier: partners get the same permissions and
  # limits as paying Pro users (setup_partner_pro_plan mirrors PRO_PLAN_LIMITS),
  # so pro? must treat it as Pro. This single predicate feeds paid_plan?,
  # partner_pro?, the lending gate, and the api_view `pro`
  # flag — so a partner is Pro everywhere those are checked. pro_yearly is
  # included for parity with the setup_limits / PLAN_LIMITS_BY_TYPE bodies.
  def pro?
    %w[pro pro_yearly partner_pro pro_5yr].include?(plan_type)
  end

  # SpeakAnyWay for Clinicians. A free, granted plan for verified clinicians
  # with Pro-level features but a small loaner cap (CLINICIAN_PLAN_LIMITS).
  # Deliberately NOT part of pro? — the reduced paid_communicator_limit is the
  # product, and widening pro? would hand clinicians Pro's 5 slots. It is a paid
  # (granted) plan for gating purposes: paid_plan? returns true so AAC usage and
  # Pro-level features never break for an approved clinician.
  def clinician?
    plan_type == "clinician"
  end

  # Lending / hand-off gate. Deliberately its own predicate rather than a
  # widened `pro?`: the Clinician plan advertises "2 loaner slots" and the whole
  # clinician workflow is lend -> family claims -> slot recycles, but folding
  # clinician into `pro?` would also hand it Pro's 5 slots and every other
  # Pro-only tool. The slot MATH is unchanged — a clinician still lends within
  # CLINICIAN_PLAN_LIMITS' 2 slots; this only says the feature exists for them.
  # See API::ChildAccountsController#require_pro_for_lending!.
  def can_lend?
    pro? || clinician?
  end

  def pro_vendor?
    plan_type.include?("pro") && role == "vendor"
  end

  def free?
    plan_type.include? "free"
  end

  # True when the user has the MySpeak feature (i.e. a demo-communicator slot).
  # MySpeak is a free feature now, so this is true for Free and Pro.
  def has_myspeak_feature?
    (settings&.dig("demo_communicator_limit") || 0).to_i > 0
  end

  def basic?
    plan_type.include? "basic"
  end

  def plus?
    plan_type.include? "plus"
  end

  # Plan statuses that mean the user is NOT actually paid right now, even if
  # plan_type is still on a paid tier. Belt-and-suspenders: the webhook *should*
  # reset plan_type to "free" on cancel/pause, but if a webhook is missed the
  # model shouldn't continue treating them as paid.
  UNPAID_STATUSES = %w[canceled paused incomplete_expired unpaid].freeze

  def paid_plan?
    return true if admin?
    return false if plan_type.blank?
    return false if UNPAID_STATUSES.include?(plan_status.to_s)
    basic? || pro? || plus? || premium? || pro_vendor? || clinician?
  end

  # True when the user is in the "stranded" limbo state: a non-paying
  # plan_status (UNPAID_STATUSES) while plan_type is still a paid tier. This
  # happens when a downgrade webhook is missed or arrives out of order (e.g. the
  # paused-subscription race). Such a user gets no paid features AND no credit
  # refresh — stuck at 0 credits indefinitely. basic_trial is excluded (owned by
  # DowngradeSoftTrialJob); free/blank plan_types are already correct.
  def plan_stranded?
    return false if admin?
    return false unless UNPAID_STATUSES.include?(plan_status.to_s)
    return false if plan_type.blank?
    return false if plan_type == "free" || plan_type == "basic_trial"
    true
  end

  # Self-heal the stranded state with no external (Stripe) call — we already
  # have everything locally. Idempotent: a no-op unless plan_stranded?. Safe to
  # call on the sign-in hot path; rescues so a reconcile failure can never block
  # sign-in (AAC usage must never break). Returns true if it reconciled.
  def reconcile_stranded_plan!
    return false unless plan_stranded?

    Billing::PlanTransitions.apply_free_plan(self, plan_status)
    Rails.logger.info "[User#reconcile_stranded_plan!] healed stranded user=#{id} -> free (was status=#{plan_status})"
    true
  rescue => e
    Rails.logger.error "[User#reconcile_stranded_plan!] user=#{id} failed: #{e.class} #{e.message}"
    false
  end

  # Settings key holding the ISO8601 moment the account entered `past_due`.
  # Written/cleared only by track_past_due_transition (and stamp_past_due!,
  # which backfills rows that went past_due before the stamp existed).
  PAST_DUE_SINCE_KEY = "past_due_since".freeze

  # Settings key holding the mapped reason the last renewal charge failed,
  # as { "reason" => <Billing::DeclineReason value>, "at" => iso8601 }. Written
  # by the invoice.payment_failed webhook and cleared alongside
  # PAST_DUE_SINCE_KEY when the account leaves past_due, so a recovered payer
  # never carries a stale reason.
  PAYMENT_FAILURE_KEY = "payment_failure".freeze

  def past_due?
    plan_status.to_s == "past_due"
  end

  # When this account entered past_due, or nil if it isn't past_due or predates
  # the stamp. Unparseable values read as nil so a junk stamp can never be
  # treated as "long expired" — the job re-stamps instead.
  def past_due_since
    raw = settings.is_a?(Hash) ? settings[PAST_DUE_SINCE_KEY] : nil
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Backfill the stamp for an account that was already past_due before the
  # stamp existed. Grace deliberately starts now, not at some guessed date —
  # `updated_at` moves on every sign-in, so there is no honest historical
  # timestamp to recover.
  def stamp_past_due!(at = Time.current)
    self.settings ||= {}
    settings[PAST_DUE_SINCE_KEY] = at.utc.iso8601
    save!
  end

  def track_past_due_transition
    self.settings ||= {}
    if past_due?
      settings[PAST_DUE_SINCE_KEY] ||= Time.current.utc.iso8601
    else
      settings.delete(PAST_DUE_SINCE_KEY)
      settings.delete(PAYMENT_FAILURE_KEY)
    end
  end

  # The past-due banner's whole payload: nil unless the account is actually
  # past_due, so the frontend checks one field instead of re-deriving the rule.
  # `reason` falls back to "generic" for a row that went past_due before the
  # reason was captured (or whose capture failed).
  def payment_issue_api_view
    return nil unless past_due?

    settings_hash = settings.is_a?(Hash) ? settings : {}
    failure = settings_hash[PAYMENT_FAILURE_KEY]
    failure = {} unless failure.is_a?(Hash)
    {
      reason: failure["reason"].presence || Billing::DeclineReason::GENERIC,
      since: settings_hash[PAST_DUE_SINCE_KEY],
    }
  end

  def professional?
    pro? || plus? || premium?
  end

  def premium?
    plan_type.include? "premium"
  end

  def to_s
    display_name
  end

  def should_send_welcome_email?
    return false if admin?
    if settings["welcome_email_sent"] == true
      return false
    end
    true
  end

  # Receipt for paid-intent (email_signup) flows: confirms account creation
  # without naming a plan, since the user hasn't picked one yet at Stripe
  # checkout. Tracked under its own flag so the later plan-specific welcome
  # (sent from the Stripe webhook on trial/active) isn't suppressed.
  def should_send_welcome_receipt_email?
    return false if admin?
    return false if settings["receipt_email_sent"] == true
    return false if settings["welcome_email_sent"] == true
    true
  end

  def send_welcome_receipt_email(raw_invitation_token: nil)
    Rails.logger.info "Sending welcome receipt email to #{email}"
    begin
      UserMailer.welcome_email_receipt(self, raw_invitation_token).deliver_later
      self.settings["receipt_email_sent"] = true
      save
      update_mailchimp_subscription
      Rails.logger.info "Welcome receipt email sent to #{email}"
    rescue => e
      Rails.logger.error("Error sending welcome receipt email: #{e.message}")
    end
  end

  # Called from the Stripe webhook on trial start / non-active→active. Sends
  # the plan-correct welcome at most once per plan_type, so re-fires of
  # subscription.updated don't re-email and a true plan change (basic→pro)
  # still sends. Independent of the email_signup receipt flag.
  def send_plan_welcome_email_once!(plan_nickname, source: "unknown")
    return if admin?
    return if plan_nickname.blank?
    plan_key = plan_nickname.to_s
    sent_for = Array(settings["plan_welcome_sent_for"])
    return if sent_for.include?(plan_key)
    send_welcome_email(plan_key)
    # Admin alert for the upgrade. Guarded to paid tiers so the billing-API
    # path can't produce a "plan change" alert for a Free account. from_plan is
    # the last plan we welcomed — an account that upgraded before this shipped
    # has an empty list and reads "free". Accepted: this is an alert, not a
    # ledger (see the design doc's known limitation).
    unless plan_key.include?("free")
      AdminMailer.plan_change_email(
        self,
        from_plan: sent_for.last || "free",
        to_plan: plan_key,
        source: source,
      ).deliver_later
    end
    self.settings["plan_welcome_sent_for"] = (sent_for + [plan_key]).uniq
    save
  end

  def new_user?
    return false if admin?
    return false if created_at < 1.hour.ago
    true
  end

  TRAIL_PERIOD = 14.days

  # True only while the user is within the 14-day free signup window AND has
  # NOT converted to a paid plan. Measures trial *state*, not raw account age:
  # a user who paid within their first 14 days is no longer "on a free trial"
  # (see #433). This matches how the frontend already treats the flag
  # (`free_trial && !paid_plan` in useTrialStatus) and prevents a bogus trial
  # countdown / free-dashboard misroute for new paying customers. `basic_trial`
  # and Stripe `trialing` count as paid_plan?, so they're excluded here too.
  def free_trial?
    return true unless created_at
    return false if paid_plan?
    created_at > TRAIL_PERIOD.ago
  end

  def trial_expired?
    !free_trial?
  end

  def trial_expired_at
    return plan_expires_at if plan_expires_at
    created_at + TRAIL_PERIOD
  end

  def trial_days_left
    (trial_expired_at - Time.now).to_i / 1.day
  end

  # --- Provider-trial surface for the client -----------------------------
  # The client must not re-derive billing rules; the server owns them. See
  # drafts/2026-07-27-trial-banner-payment-method-design.md.
  #
  # Deliberately separate from free_trial? / trial_days_left, which describe
  # the 14-day-from-signup window for Free accounts. That window is unrelated
  # to a provider trial and keeps its own client behavior.

  # Which provider runs the current trial. Stripe trials always carry a
  # stripe_subscription_id; RevenueCat (IAP) trials never do.
  def trial_provider
    return nil unless show_trial_ui?

    stripe_subscription_id.present? ? "stripe" : "revenuecat"
  end

  # Should the client show trial UI at all? partner_pro pilots ride a 3-month
  # no-card trial managed outside the app, so a persistent 90-day countdown
  # strip is noise for them.
  def show_trial_ui?
    plan_status == "trialing" && plan_type != "partner_pro"
  end

  # True only when adding a card is the action that keeps the user's plan: a
  # Stripe reverse trial (#264) with nothing on file. RevenueCat trialists
  # already pay through Apple/Google and cannot add a card here at all.
  def trial_needs_payment_method?
    show_trial_ui? &&
      trial_provider == "stripe" &&
      !(settings || {})["has_payment_method"]
  end

  # Display name of the plan being trialed, for banner copy. nil for tiers
  # without a consumer-facing label — the client falls back to generic copy.
  def trial_plan_label
    return nil unless show_trial_ui?
    return "Pro" if pro?
    return "Basic" if basic?

    nil
  end

  # How many of this user's boards would become read-only if the trial ended
  # right now with no card on file — the number the day-11 warning quotes.
  #
  # It has to be computed against the plan they are ABOUT to land on, not the
  # one they are on: mid-trial they hold a Basic or Pro limit and nothing is
  # over it, so the naive `countable_board_count - editable_board_ids.size` is
  # always 0 while the trial is running. Free is where a lapsed no-card trial
  # lands (`missing_payment_method: "cancel"` -> subscription deleted ->
  # apply_free_plan), so Free's numbers are the ones that matter.
  #
  # Zero whenever nothing is going to lock: no trial, a card already on file
  # (the trial converts), a RevenueCat trial (they paid through the store), or
  # an admin (never board-locked).
  def boards_locking_at_trial_end
    return 0 if admin?
    return 0 unless trial_needs_payment_method?

    free_limit = self.class.plan_limits_for("free")["board_limit"].to_i
    free_editable_slots = [free_limit, EDITABLE_BOARD_FLOOR].max
    [countable_board_count - free_editable_slots, 0].max
  end

  def trial_api_view
    {
      active: show_trial_ui?,
      status: plan_status,
      ends_at: (settings || {})["trial_ends_at"],
      provider: trial_provider,
      needs_payment_method: trial_needs_payment_method?,
      plan_label: trial_plan_label,
      # Lets the banner say what actually happens at the end of the trial
      # instead of only that it is ending. 0 means "nothing locks" — the
      # client shows the plain countdown.
      boards_locking: boards_locking_at_trial_end,
    }
  end

  def startup_board_group
    startup_board_group_id = settings["startup_board_group_id"]
    board_group = BoardGroup.includes(board_group_boards: :board).find_by(id: startup_board_group_id) if startup_board_group_id
    return board_group if board_group
    BoardGroup.startup
  end

  include ActionView::Helpers::DateHelper

  def admin_index_view
    view = as_json
    view["board_count"] = boards.count
    view["ai_credits"] = CreditService.balance(self)
    view["stripe_customer_id"] = stripe_customer_id
    view["trial_days_left"] = trial_days_left
    view["last_sign_in_at"] = time_ago_in_words(last_sign_in_at) if last_sign_in_at
    view["last_sign_in_ip"] = last_sign_in_ip
    view["current_sign_in_at"] = current_sign_in_at
    view["current_sign_in_ip"] = current_sign_in_ip
    view["sign_in_count"] = sign_in_count
    view["plan_type"] = plan_type
    view["plan_expires_at"] = plan_expires_at.strftime("%x") if plan_expires_at
    view["free_trial"] = free_trial?
    view["trial_expired"] = trial_expired?
    view["free"] = free?
    view
  end

  def comm_account_limit_reached
    settings["paid_communicator_limit"].to_i + extra_communicator_slots + settings["demo_communicator_limit"].to_i <= communicator_accounts.count
  end

  def admin_api_view
    view = as_json
    # Read through the model, never re-derived from settings: `board_limit`
    # resolves from plan_type now, and `countable_board_count` / `at_board_limit?`
    # are what actually gate creation. `board_limit_source` tells an admin whether
    # they are looking at a deliberate override or the plan default.
    board_limit = self.board_limit
    board_count = countable_board_count
    board_limit_reached = at_board_limit?
    board_limit_source = (settings || {})["board_limit"].present? ? "override" : "plan"
    view["admin"] = admin?
    view["free"] = free?
    view["pro"] = pro?
    view["basic"] = basic?
    view["plan_type"] = plan_type
    view["plan_expires_at"] = plan_expires_at.strftime("%x") if plan_expires_at
    view["premium"] = premium?
    view["team"] = current_team
    view["free_trial"] = free_trial?
    view["trial_expired"] = trial_expired?
    view["trial_days_left"] = trial_days_left
    view["last_sign_in_at"] = last_sign_in_at
    view["last_sign_in_ip"] = last_sign_in_ip
    view["current_sign_in_at"] = current_sign_in_at
    view["current_sign_in_ip"] = current_sign_in_ip
    view["sign_in_count"] = sign_in_count
    view["tokens"] = tokens
    view["ai_credits"] = CreditService.balance(self)
    view["phrase_board_id"] = settings["phrase_board_id"]
    view["opening_board_id"] = settings["opening_board_id"]
    view["has_dynamic_default"] = opening_board.present?
    view["startup_board_group_id"] = settings["startup_board_group_id"]
    view["communicator_accounts"] = communicator_accounts.map(&:api_view)
    view["boards"] = boards.distinct.order(name: :asc).map(&:user_api_view)
    view["scenarios"] = scenarios.map(&:api_view)
    view["images"] = images.order(:created_at).limit(10).map { |image| { id: image.id, name: image.name, src: image.src_url } }
    view["display_name"] = display_name
    view["stripe_customer_id"] = stripe_customer_id
    view["board_limit"] = board_limit
    view["board_limit_source"] = board_limit_source
    view["board_count"] = board_count
    view["comm_account_limit_reached"] = comm_account_limit_reached
    view["board_limit_reached"] = board_limit_reached
    view["can_create_boards"] = can_create_boards
    view["settings"] = settings
    view["settings"]["plan_type"] = plan_type
    view["signup_ref"] = settings["signup_ref"]
    view["partner_pro"] = partner_pro?
    view["plan_status"] = plan_status
    view["paid_plan_type"] = paid_plan_type
    view
  end

  def teams_with_read_access
    teams.joins(:team_users)
         .where(team_users: { user_id: id, role: %w[supervisor member] })
         .where.not(teams: { created_by_id: id })
         .distinct
  end

  def favorite_boards
    boards.where(favorite: true).order(name: :asc)
  end

  def go_to_boards
    favorite_boards.any? ? favorite_boards : boards.alphabetical.limit(10)
  end

  def vendor?
    role == "vendor"
  end

  def vendor_account
    return nil unless vendor?
    ChildAccount.find_by(user_id: id, vendor_id: vendor_id) if vendor_id
  end

  def vendor_profile
    return nil unless vendor?
    vendor_account&.profile
  end

  # AI access is gated by the credit ledger at the controller layer
  # (`check_credits!` → HTTP 402). This flag only answers "is the account
  # allowed to touch AI at all", which is purely a function of the lock state.
  def can_use_ai?
    !locked?
  end

  # Single source of truth for "how many boards count against the limit."
  # Excludes predefined (admin-curated) boards; EVERY board the user owns
  # otherwise counts, Board Builder sets included. There is exactly one creation
  # cap — boards — because a Board Set cannot exist without them, and two caps
  # for one resource is what let a user at their board limit run the builder,
  # receive a whole tree, and still be told "1 of 1 boards" (issue #796). Board
  # Sets themselves are uncapped. Memoized because board list serialization
  # calls board_editable? once per board.
  def countable_board_count
    @countable_board_count ||= boards.where(predefined: false).count
  end

  # The one gate every board-creation path checks. Admins are never limited.
  def at_board_limit?
    return false if admin?

    countable_board_count >= board_limit
  end

  # How many more boards this user may create. Lives here rather than only in
  # BoardCreationLimit so a SERVICE can budget a multi-board create without
  # reaching into a controller concern — Boards::CloneSetPlanner sizes a copied
  # board set against it. Admins are unlimited, and `Float::INFINITY` is
  # deliberate: every caller compares or takes a `min` with it, and a sentinel
  # integer would silently cap an admin at that number.
  def board_limit_remaining
    return Float::INFINITY if admin?

    [board_limit - countable_board_count, 0].max
  end

  def can_create_boards
    !at_board_limit?
  end

  # Board Sets the user owns, excluding predefined (admin-curated) ones. NOT a
  # cap any more — Board Set creation is uncapped, since the boards inside a set
  # are what count (see countable_board_count). Kept as a real usage number for
  # api_view and the board_groups rake reports.
  def countable_board_group_count
    board_groups.where(predefined: [false, nil]).count
  end

  # The single board a limited-plan user keeps full edit access to. Returns
  # the board they designated; if that's missing, falls back to a favorite or
  # most-recently-updated owned board so a freshly-downgraded user is never
  # locked out of everything before they pick one.
  def effective_editable_board_id
    return @effective_editable_board_id if defined?(@effective_editable_board_id)

    @effective_editable_board_id =
      if editable_board_id && total_boards.exists?(id: editable_board_id)
        editable_board_id
      else
        boards.where(predefined: false)
              .order(favorite: :desc, updated_at: :desc)
              .limit(1)
              .pick(:id)
      end
  end

  # Pin a default editable board after a downgrade so the user has a working
  # edit slot immediately. Idempotent — only writes when editable_board_id
  # is blank, and only if effective_editable_board_id resolves to a board.
  # Called from both downgrade paths: apply_free_plan (Stripe cancel/pause)
  # and DowngradeSoftTrialJob (soft-trial expiry).
  #
  # Deliberately does NOT set editable_board_id_set_at — the initial default
  # is the system's pick, not the user's. The user's first explicit
  # make_editable call starts the cooldown clock.
  def pin_default_editable_board!
    return unless editable_board_id.blank?
    default_id = effective_editable_board_id
    return if default_id.blank?
    update_column(:editable_board_id, default_id)
  end

  # Reconcile which of this user's communicators are in "fallback mode" after a
  # plan change (issue #255). Keeps the most-recently-active slotted
  # communicators (up to the plan's slot limit) signable and flags the overflow
  # as fallback. Runs in both directions from one place:
  #
  #   - Downgrade (paid -> free): slot_limit drops, the overflow gets flagged so
  #     their boards/MySpeak/public_url survive but private sign-in is blocked.
  #   - Re-upgrade (free -> paid): slot_limit rises, the now-in-limit
  #     communicators are restored most-recently-active first; any still over the
  #     new limit stay in fallback.
  #
  # Idempotent. Only ever touches slotted (loaner/active) communicators, so a
  # fresh Free signup (capped at 1) is never flagged. Admins are never limited.
  def reconcile_communicator_fallback!
    limit = Permissions::CommunicatorLimits.slot_limit_for(settings || {})
    limit = nil if admin?

    accounts = slotted_communicator_accounts
                 .order(Arel.sql("last_sign_in_at DESC NULLS LAST, updated_at DESC, id DESC"))
                 .to_a

    # Owner-chosen priority (issue #439): communicators the owner explicitly
    # pinned to keep signable move to the front, in the order they picked them;
    # everything unpinned keeps the most-recently-active ordering. So which
    # communicators stay full vs. fall back is the owner's call, not just
    # whichever signed in last. No pick ⇒ the historical recency rule.
    kept = kept_communicator_ids
    unless kept.empty?
      pinned, rest = accounts.partition { |account| kept.include?(account.id) }
      pinned.sort_by! { |account| kept.index(account.id) }
      accounts = pinned + rest
    end

    accounts.each_with_index do |account, index|
      keep = limit.nil? || index < limit
      if keep
        account.exit_fallback! if account.fallback_mode?
      else
        account.enter_fallback! unless account.fallback_mode?
      end
    end
  end

  # The communicators the owner has explicitly pinned to keep signable when over
  # the slot limit (issue #439). Stored on settings as an array of ids; read back
  # sanitized to integers. Empty ⇒ no explicit pick, so reconcile falls back to
  # the most-recently-active rule.
  KEPT_COMMUNICATOR_IDS_KEY = "kept_communicator_ids".freeze

  def kept_communicator_ids
    Array(settings && settings[KEPT_COMMUNICATOR_IDS_KEY]).map(&:to_i)
  end

  # Persist the owner's pinned set and re-run reconcile so the choice takes
  # effect immediately. Only ids the user actually owns as slotted (loaner/active)
  # communicators are honored; the set is capped at the current slot limit (extra
  # pins are dropped, keeping the order the owner sent). Returns the stored ids.
  def set_kept_communicator_ids!(ids)
    owned = slotted_communicator_accounts.pluck(:id)
    requested = Array(ids).map(&:to_i).uniq.select { |id| owned.include?(id) }
    limit = Permissions::CommunicatorLimits.slot_limit_for(settings || {})
    requested = requested.first(limit) if limit
    self.settings ||= {}
    self.settings[KEPT_COMMUNICATOR_IDS_KEY] = requested
    save!
    reconcile_communicator_fallback!
    requested
  end

  # Promote sandbox communicators to full (active) accounts up to the number of
  # free paid slots (issue #359). A Free user's self-creates are forced to
  # sandbox; on upgrade to a plan that grants NO sandbox slots, those leftovers
  # should become full communicators with sign-in. Promotes most-recently-active
  # first so the user's primary communicator is converted before any extras.
  #
  # Gated to plans with **zero sandbox entitlement** (Basic — see
  # BASIC_PLAN_LIMITS["demo_communicator_limit"] == 0). Pro grants 1 sandbox
  # slot, so a Pro user's sandbox is an intentional scratch/demo account and is
  # left untouched. No-op for Free/unpaid users and admins. Idempotent.
  def reconcile_paid_sandbox_promotions!
    return if admin?
    return unless paid_plan?
    return if Permissions::CommunicatorLimits.sandbox_limit_for(settings || {}) > 0

    slot_limit = Permissions::CommunicatorLimits.slot_limit_for(settings || {})
    available = slot_limit - Permissions::CommunicatorLimits.owned_slot_count(self)
    return if available <= 0

    communicator_accounts
      .where(status: ChildAccount::SANDBOX)
      .order(Arel.sql("last_sign_in_at DESC NULLS LAST, updated_at DESC, id DESC"))
      .limit(available)
      .each(&:promote_to_active!)
  end

  # How long a user must wait between editable-board switches. Closes the
  # loophole where a free user could rotate the editable slot to edit every
  # board one at a time. Configurable for support / experimentation.
  EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS =
    ENV.fetch("EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS", 14).to_i

  # When the next make_editable call is permitted. Nil if no prior explicit
  # pick (so the user can pick immediately) or if the cooldown has passed.
  def editable_board_switch_available_at
    return nil if editable_board_id_set_at.blank?
    available = editable_board_id_set_at + EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS.days
    available > Time.current ? available : nil
  end

  def editable_board_switch_cooldown_active?
    editable_board_switch_available_at.present?
  end

  # Whether this user may edit the given board's content. Board-limited plans
  # over their board limit can edit only a subset of their boards; everything
  # else they own becomes read-only (still fully usable — view/tap/audio, AAC
  # usage never breaks). Full paid plans (Basic/Pro/licenses/Partner Pro) are
  # never board-locked — their limit only gates creation. See editable_board_ids
  # for how the editable subset is chosen (the designated make_editable pick,
  # then most-recently-updated boards up to `editable_slot_count` — the plan's
  # board limit or EDITABLE_BOARD_FLOOR, whichever is kinder).
  def board_editable?(board)
    return true if admin?
    return true if board.nil? || board.user_id != id
    return true unless board_limit_locks?
    return true if countable_board_count <= board_limit

    editable_board_ids.include?(board.id)
  end

  # True when this user's plan enforces the over-limit read-only board lock: any
  # non-paid plan (Free / stranded), plus the free **Clinician** plan (paid for
  # gating, but its Basic-shaped board limit is the product, so over-limit boards
  # go view-only just like Free). Full paid plans are exempt.
  def board_limit_locks?
    return true unless paid_plan?
    clinician?
  end

  # How many boards stay editable when a locked plan is over its board limit.
  #
  # This is deliberately NOT `board_limit`. The limit governs how many boards
  # you may CREATE; this governs how much of what you already made stays
  # writable once you are past it, and the two stopped being the same question
  # when #801 made Board Builder boards count. A Free account that ran the
  # builder lands 23-35 boards over a limit of 1, and collapsing that to a
  # single editable board is a cliff — the boards are all still usable for
  # communication, but a parent who spent a fortnight building a set can only
  # edit one of them.
  #
  # The floor makes Free behave the way every other locked plan already did.
  # Clinician (limit 100) keeps its hundred most-recent boards editable; Free
  # kept exactly one, purely because its limit happens to be 1. Now both fill
  # by the same rule, and Free stops being a special case.
  #
  # It grants nothing: you still cannot CREATE a second board on Free, the
  # pricing page's "1 board" is still true, and `at_board_limit?` is untouched.
  # ENV-overridable like the plan limits themselves, so it can be retuned from
  # Hatchbox without a deploy.
  EDITABLE_BOARD_FLOOR = ENV.fetch("EDITABLE_BOARD_FLOOR", 5).to_i

  # The number of editable slots this user gets while locked — their plan's
  # board limit, or the floor, whichever is kinder.
  def editable_slot_count
    [board_limit.to_i, EDITABLE_BOARD_FLOOR].max
  end

  # The set of this user's board ids that stay editable when over the board
  # limit: the designated `make_editable` pick, then the rest of the slots
  # filled by their most-recently-updated owned boards (favorites first) — the
  # active work stays editable, stale boards lock.
  def editable_board_ids
    # The explicit make_editable pick is pinned first, then the rest of the
    # slots fill by recency. Without the pin, a locked plan ignored
    # `editable_board_id` outright, so make_editable answered 200 and changed
    # nothing at all — a silent no-op with no error in the UI.
    pinned = [effective_editable_board_id].compact
    (pinned + top_editable_board_ids).uniq.first(editable_slot_count)
  end

  # Fills the editable slots by recency. `editable_board_ids` pins the explicit
  # make_editable pick ahead of this list, so a pick that isn't in here takes a
  # slot from the least-recently-updated board rather than adding one.
  def top_editable_board_ids
    @top_editable_board_ids ||=
      boards.where(predefined: false)
            .order(favorite: :desc, updated_at: :desc)
            .limit(editable_slot_count)
            .pluck(:id)
  end

  def public_page_url
    profile&.public_url
  end

  # Status of this user's most recent clinician application ("pending",
  # "approved", or "denied"), or nil if they've never applied. Derived from the
  # application record rather than a denormalized column: approval already
  # flips plan_type, so "pending" is the only state the frontend can't
  # otherwise see, and a stored copy would just be one more thing to keep in
  # sync with the admin review queue.
  def clinician_application_status
    clinician_applications.order(created_at: :desc).limit(1).pick(:status)
  end

  def api_view
    plan_exp = plan_expires_at&.strftime("%x")

    # ---- Limits from Stripe/user settings ----
    comm_limit = (settings["paid_communicator_limit"] || 0).to_i + extra_communicator_slots # REAL communicators included (base + Pro add-on slots)
    demo_limit = (settings["demo_communicator_limit"] || 0).to_i     # DEMO communicators allowed
    board_limit = self.board_limit

    # ---- Memoize common collections ----
    memoized_teams = teams_with_read_access
    memoized_communicators = communicator_accounts.limit(5)

    # ---- Counts ----
    # The number the CAP enforces, so board_count / board_limit_reached /
    # can_create_boards can no longer disagree in one payload (they used to:
    # board_count was every board incl. predefined, board_limit_reached compared
    # it against a locally re-read setting, and can_create_boards used the real
    # gate two lines below).
    board_count = countable_board_count

    paid_comm_count = paid_communicator_accounts.length
    demo_comm_count = demo_communicator_accounts.length

    # ---- Status-aware counts (loaner-lifecycle, issue #156) ----
    # Single query, grouped by status, so we don't fire one query per
    # association. Used by the dashboard slot counter + LoanerControls.
    status_counts = communicator_accounts.group(:status).count
    sandbox_count = status_counts.fetch(ChildAccount::SANDBOX, 0)
    loaner_count  = status_counts.fetch(ChildAccount::LOANER, 0)
    active_count  = status_counts.fetch(ChildAccount::ACTIVE, 0)

    # ---- Derived limits ----
    paid_comm_limit_total = comm_limit

    # ---- Limit reached flags ----
    paid_comm_account_limit_reached = paid_comm_limit_total <= paid_comm_count
    demo_comm_account_limit_reached = demo_limit <= demo_comm_count

    remaining_paid_accounts = [0, paid_comm_limit_total - paid_comm_count].max
    remaining_demo_accounts = [0, demo_limit - demo_comm_count].max
    {
      id: id,
      organization_id: organization_id,
      # Pending-invite accounts (email_signup, webhook-invited) — drives the
      # frontend's post-checkout "set a password" prompt. Not
      # encrypted_password.blank?: devise_invitable assigns a random password
      # on invite!, but valid_password? is nil until the invitation is
      # accepted, so a pending invite is effectively passwordless.
      needs_password: invited_to_sign_up?,
      # Drives the "verify your email" banner. Unverified accounts hold no
      # welcome tokens until they click the link — see mark_email_verified!.
      email_verified: email_verified?,
      profile: profile&.user_api_view,
      delete_account_token: delete_account_token,
      public_page_url: public_page_url,
      slug: slug,
      public_url: public_url,
      # vendor_profile: vendor_profile&.api_view,
      is_vendor: vendor?,

      # Boards
      board_limit: board_limit,
      board_count: board_count,
      # NOT board_count > 0: this drives the dashboard empty state and has to
      # keep meaning "owns any board at all", so a user whose only boards are
      # predefined isn't shown the empty state.
      has_boards: boards.exists?,
      board_limit_reached: at_board_limit?,
      # Board Set usage. No limit alongside it any more — Board Sets are
      # uncapped; the boards inside them are what count (issue #796).
      board_group_count: countable_board_group_count,
      can_create_boards: can_create_boards,
      editable_board_id: effective_editable_board_id,
      editable_board_switch_available_at: editable_board_switch_available_at,
      editable_board_switch_cooldown_days: EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS,

      # AI
      can_use_ai: can_use_ai?,

      # Identity
      email: email,
      # Account age drives the dashboard's first-visit vs. "Welcome back"
      # greeting (isNewAccount treats a missing/unparseable value as unknown,
      # not as "new"), so this has to be a parseable timestamp, not a
      # locale-formatted date like plan_expires_at.
      created_at: created_at,
      role: role,
      name: name,
      display_name: display_name,
      admin: admin?,

      # Plan flags
      free: free?,
      pro: pro?,
      # Clinician is not Pro (see clinician?), so the frontend can't infer
      # either of these from `pro`. can_lend is the server-owned answer to
      # "show the Lend & hand-off controls" — the gate and the UI must agree or
      # the button 403s.
      clinician: clinician?,
      can_lend: can_lend?,
      basic: basic?,
      plus: plus?,
      premium: premium?,
      paid_plan: paid_plan?,
      myspeak: has_myspeak_feature?,
      professional: professional?,
      basic_vendor: vendor? && basic?,
      vendor: vendor?,
      plan_type: plan_type,
      plan_status: plan_status,
      # Drives the "your clinician application is under review" notice
      # on the dashboard. nil for the vast majority of users.
      clinician_application_status: clinician_application_status,
      plan_expires_at: plan_exp,
      free_trial: free_trial?,
      trial_expired: trial_expired?,
      trial_days_left: trial_days_left,
      trial: trial_api_view,
      # nil unless the account is past_due. Names WHY the charge failed so the
      # banner can give the right next action; see Billing::DeclineReason.
      payment_issue: payment_issue_api_view,
      comm_account_limit_reached: comm_account_limit_reached,

      # Communicators (REAL)
      accounts_included: comm_limit,
      comm_account_limit: paid_comm_limit_total,
      paid_communicator_count: paid_comm_count,
      paid_comm_account_limit_reached: paid_comm_account_limit_reached,

      # Owner's pinned "keep signable" set + the plan slot limit, so the
      # over-limit picker (issue #439) can pre-check the right toggles.
      communicator_slot_limit: Permissions::CommunicatorLimits.slot_limit_for(settings || {}),
      kept_communicator_ids: kept_communicator_ids,

      # Communicators (DEMO)
      demo_comm_account_limit: demo_limit,
      demo_comm_account_limit_reached: demo_comm_account_limit_reached,
      demo_communicator_count: demo_comm_count,

      # Lifecycle counts (loaner-lifecycle, issue #156). Active+loaner
      # together count against comm_account_limit. Free hosts one
      # claimed; claimed_communicator_count = active for Free users.
      sandbox_communicator_count: sandbox_count,
      loaner_communicator_count: loaner_count,
      active_communicator_count: active_count,
      claimed_communicator_count: active_count,

      # Other settings-driven limits
      supervisor_limit: settings["supervisor_limit"] || 0,
      phrase_board_id: settings["phrase_board_id"],
      opening_board_id: settings["opening_board_id"],
      has_dynamic_default: opening_board.present?,
      startup_board_group_id: settings["startup_board_group_id"],

      # Teams / accounts / boards
      # current_team: current_team,
      teams_with_read_access: memoized_teams.map(&:index_api_view),

      # If these are AR objects, you may already have a serializer.
      # If not, consider mapping them to api_view here for consistency.
      communicator_accounts: memoized_communicators.map(&:index_api_view),
      # paid_communicator_accounts: paid_communicator_accounts.map(&:index_api_view),
      # demo_communicator_accounts: demo_communicator_accounts.map(&:index_api_view),
      remaining_demo_accounts: remaining_demo_accounts,
      remaining_paid_accounts: remaining_paid_accounts,

      # go_to_words: go_words,
      # go_to_boards: go_to_boards.map { |b| { id: b.id, name: b.name, display_image_url: b.display_image_url, slug: b.slug, ionic_icon: b.ionic_icon } },
      # boards: memoized_boards.map { |b| { id: b.id, name: b.name, word_sample: b.word_sample, frozen: b.is_frozen? } },

      # most_clicked_words: most_clicked_words,

      last_sign_in_at: last_sign_in_at,
      last_sign_in_ip: last_sign_in_ip,
      current_sign_in_at: current_sign_in_at,
      current_sign_in_ip: current_sign_in_ip,
      sign_in_count: sign_in_count,

      tokens: tokens,
      settings: settings,
      stripe_customer_id: stripe_customer_id,

      unread_messages: messages.where(recipient_id: id, read_at: nil, recipient_deleted_at: nil).count,
      paid_plan_type: paid_plan_type,
    }
  end

  def soft_delete_account!(
    reason: "user_requested",
    platform: "web",
    actor_id: nil,
    cancel_immediately: true,
    detach_payment_methods: true,
    delete_stripe_customer: false
  )
    if stripe_customer_id
      soft_delete_stripe_customer!(
        reason: reason,
        actor_id: actor_id,
        detach_payment_methods: detach_payment_methods,
        delete_stripe_customer: delete_stripe_customer,
      )
    else
      enqueue_deletion_cleanup!(reason: reason)
      anonymize_personal_data_and_delete_all_data!(deleted_at: Time.current, reason: reason, actor_id: actor_id)
    end
  end

  def username
    email.split("@").first
  end

  def slug
    profile&.slug || "#{username}-#{id}".parameterize
  end

  def startup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/vendors/sign-in?username=#{username}"
  end

  def setup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/pro-accounts/#{id}/qr"
  end

  def public_url
    return nil if slug.blank?
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"

    "#{base_url}/u/#{slug}"
  end

  def self.to_csv
    users = all
    csv_column_names = %w[id email name role created_at updated_at plan_type plan_expires_at plan_status tokens stripe_customer_id]
    CSV.generate do |csv|
      csv << csv_column_names
      users.each do |user|
        csv << user.attributes.values_at(*csv_column_names)
      end
    end
  end
end
