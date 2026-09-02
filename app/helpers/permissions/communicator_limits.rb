module Permissions
  module CommunicatorLimits
    extend self

    # Stable error codes for a refusal. The prose strings these ride alongside
    # are what the frontend renders today, and they name no limit and offer no
    # path — a clinician at 2/2 saw "Maximum number of communicator accounts
    # reached." mid-form with nothing to act on (#820). The code plus the
    # limit/count from `usage_for` are what let the frontend say something
    # useful without any copy moving into the backend.
    UNAUTHORIZED = "unauthorized"
    UNKNOWN_STATUS = "unknown_communicator_status"
    SLOTS_NOT_INCLUDED = "communicator_slots_not_included"
    SLOT_LIMIT_REACHED = "communicator_limit_reached"
    SANDBOX_NOT_INCLUDED = "sandbox_communicators_not_included"
    SANDBOX_LIMIT_REACHED = "sandbox_limit_reached"

    # The statuses that occupy a slot. A `loaner` counts against the lender
    # until a family claims it, which is when the slot comes back.
    SLOT_STATUSES = [ChildAccount::LOANER, ChildAccount::ACTIVE].freeze

    # Slot math:
    #
    #   Free  — 1 full (login) communicator, CLAIM/HAND-OFF ONLY. A Free user
    #           never self-creates a full communicator: every self-create is a
    #           no-login sandbox "MySpeak Free account" (see self_create_status).
    #           The 1 paid slot only ever fills via a claim (see can_claim?).
    #   Basic — 2 communicators (loaner + active total).
    #   Pro   — 5 communicators, loaner-capable, recycling.
    #
    # A `loaner` counts against the owner's (SLP's) slot. On claim the
    # ownership transfers and the slot frees on the SLP's side (see B4).
    #
    # Returns: [allowed(Boolean), http_status(Symbol), error_message(String|nil),
    #           error_code(String|nil)]
    #
    # The 4th element is a stable, machine-readable code (the constants above). It
    # is appended rather than replacing the prose string because the frontend
    # renders `error` verbatim today — every message here stays byte-identical.
    # Existing three-target destructuring keeps working unchanged.
    def can_create?(user:, is_demo: nil, status: nil)
      return [false, :unauthorized, "Unauthorized", UNAUTHORIZED] unless user

      status ||= is_demo ? ChildAccount::SANDBOX : ChildAccount::ACTIVE
      settings = user.settings || {}

      case status
      when ChildAccount::SANDBOX
        check_sandbox_quota(user, settings)
      when ChildAccount::LOANER, ChildAccount::ACTIVE
        check_slot_self_create(user)
      else
        [false, :unprocessable_content, "Unknown communicator status: #{status}", UNKNOWN_STATUS]
      end
    end

    # Slot check for receiving a *claimed* communicator (B4). Unlike
    # self-create, Free users may host 1 claimed slot — that's the whole
    # point of the hand-off — so this skips the self-create paywall.
    def can_claim?(user:)
      return [false, :unauthorized, "Unauthorized", UNAUTHORIZED] unless user

      refuse_when_out_of_slots(slots_for(user: user))
    end

    # The status a *self-created* communicator must take for this user. A Free
    # user never self-creates a full (login) communicator — their one paid slot
    # is reserved for a claim/hand-off (see can_claim?) — so every self-create
    # (the generic create form AND the MySpeak onboarding wizard) is forced to a
    # no-login sandbox "MySpeak Free account", regardless of what was requested.
    # Paid plans self-create whatever they asked for. The frontend mirrors this
    # in communicator_status.defaultSelfCreateIsSandbox.
    def self_create_status(user:, requested:)
      return ChildAccount::SANDBOX if user&.free?

      requested
    end

    # The limit/count pair `can_create?` decided against, for the analytics
    # event fired on a refusal (#766) — `can_create?` returns only a message, so
    # without this the event carries no numbers and can't tell "plan has no
    # slots" apart from "all slots full". Costs a count query, so call it on the
    # REFUSAL path only.
    def usage_for(user:, status:)
      return { limit: 0, count: 0 } unless user

      settings = user.settings || {}

      if status == ChildAccount::SANDBOX
        {
          limit: sandbox_limit_for(settings),
          count: user.communicator_accounts.where(status: ChildAccount::SANDBOX).count,
        }
      else
        { limit: slot_limit_for(settings), count: owned_slot_count(user) }
      end
    end

    # The total non-sandbox slots a user occupies right now. Used by the
    # claim flow and by frontends rendering "X of Y communicators."
    def owned_slot_count(user)
      user.communicator_accounts.where(status: SLOT_STATUSES).count
    end

    # THE answer to "how many communicator slots does this user have left",
    # derived from the exact limit and count `can_create?` refuses on, so a
    # payload field can no longer disagree with the 422 it predicts.
    #
    # It exists because two flags used to answer this and they were opposites
    # at the same instant (#824): `comm_account_limit_reached` summed the paid
    # AND sandbox limits against EVERY communicator — matching no gate anywhere
    # — so a clinician at 2/2 with one communicator out on loan read `false`
    # there and `true` in `paid_comm_account_limit_reached`, while the create
    # 422'd. One panel rendered "2 of 2 slots in use" directly above "No slots
    # available" because two components had picked different fields.
    #
    # `status_counts` lets a caller that already grouped by status (User#api_view)
    # pass its counts in rather than firing the query twice.
    def slots_for(user:, status_counts: nil)
      return { limit: 0, used: 0, available: 0, on_loan: 0, active: 0, limit_reached: true } unless user

      counts = status_counts || user.communicator_accounts.group(:status).count
      on_loan = counts.fetch(ChildAccount::LOANER, 0)
      active = counts.fetch(ChildAccount::ACTIVE, 0)
      limit = slot_limit_for(user.settings || {})
      used = on_loan + active

      {
        limit: limit,
        used: used,
        available: [0, limit - used].max,
        on_loan: on_loan,
        active: active,
        # `>=`, not `>`: a plan with no slots at all is "reached" too, since
        # `check_slot_self_create` refuses that case as well (403
        # SLOTS_NOT_INCLUDED rather than 422, but refuses either way).
        limit_reached: used >= limit,
      }
    end

    def slot_limit_for(settings)
      base = (settings["communicator_slot_limit"] || settings["paid_communicator_limit"] || 0).to_i
      base + extra_communicator_slots_for(settings)
    end

    # Pro-only add-on slots purchased on top of the plan's base limit. Kept as a
    # literal key (not the Billing::ExtraCommunicators constant) so this
    # low-level permission helper carries no service dependency. See
    # Billing::ExtraCommunicators for the purchase paths that write it.
    def extra_communicator_slots_for(settings)
      (settings["extra_communicator_slots"] || 0).to_i
    end

    def sandbox_limit_for(settings)
      (settings["sandbox_communicator_limit"] || settings["demo_communicator_limit"] || 0).to_i
    end

    def self_create_allowed?(user)
      return true if user.admin?
      slot_limit_for(user.settings || {}) > 0
    end

    private

    def check_sandbox_quota(user, settings)
      limit = sandbox_limit_for(settings)
      count = user.communicator_accounts.where(status: ChildAccount::SANDBOX).count

      return [false, :forbidden, "Your plan does not include sandbox communicators.", SANDBOX_NOT_INCLUDED] if limit <= 0
      return [false, :unprocessable_content, "Sandbox communicator limit reached.", SANDBOX_LIMIT_REACHED] if count >= limit

      [true, :ok, nil, nil]
    end

    def check_slot_self_create(user)
      refuse_when_out_of_slots(slots_for(user: user))
    end

    # The one place a slot refusal is decided, so `slots_for(...)[:limit_reached]`
    # — which the payload publishes — cannot disagree with the answer this gate
    # gives. Both messages stay byte-identical: the frontend renders them verbatim.
    def refuse_when_out_of_slots(slots)
      return [false, :forbidden, "Your plan does not include communicator accounts.", SLOTS_NOT_INCLUDED] if slots[:limit] <= 0
      return [false, :unprocessable_content, "Maximum number of communicator accounts reached.", SLOT_LIMIT_REACHED] if slots[:limit_reached]

      [true, :ok, nil, nil]
    end
  end
end
