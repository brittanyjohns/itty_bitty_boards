module Permissions
  module CommunicatorLimits
    extend self

    # Slot math:
    #
    #   Free  — 1 communicator (self-created or claimed). Plus the no-login
    #           sandbox.
    #   Basic — 2 communicators (loaner + active total).
    #   Pro   — 5 communicators, loaner-capable, recycling.
    #
    # A `loaner` counts against the owner's (SLP's) slot. On claim the
    # ownership transfers and the slot frees on the SLP's side (see B4).
    #
    # Returns: [allowed(Boolean), http_status(Symbol), error_message(String|nil)]
    def can_create?(user:, is_demo: nil, status: nil)
      return [false, :unauthorized, "Unauthorized"] unless user

      status ||= is_demo ? ChildAccount::SANDBOX : ChildAccount::ACTIVE
      settings = user.settings || {}

      case status
      when ChildAccount::SANDBOX
        check_sandbox_quota(user, settings)
      when ChildAccount::LOANER, ChildAccount::ACTIVE
        check_slot_self_create(user, settings)
      else
        [false, :unprocessable_entity, "Unknown communicator status: #{status}"]
      end
    end

    # Slot check for receiving a *claimed* communicator (B4). Unlike
    # self-create, Free users may host 1 claimed slot — that's the whole
    # point of the hand-off — so this skips the self-create paywall.
    def can_claim?(user:)
      return [false, :unauthorized, "Unauthorized"] unless user

      settings = user.settings || {}
      slot_limit = slot_limit_for(settings)
      owned_count = owned_slot_count(user)

      return [false, :forbidden, "Your plan does not include communicator accounts."] if slot_limit <= 0
      return [false, :unprocessable_entity, "Maximum number of communicator accounts reached."] if owned_count >= slot_limit

      [true, :ok, nil]
    end

    # The total non-sandbox slots a user occupies right now. Used by the
    # claim flow and by frontends rendering "X of Y communicators."
    def owned_slot_count(user)
      user.communicator_accounts.where(status: [ChildAccount::LOANER, ChildAccount::ACTIVE]).count
    end

    def slot_limit_for(settings)
      (settings["communicator_slot_limit"] || settings["paid_communicator_limit"] || 0).to_i
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

      return [false, :forbidden, "Your plan does not include sandbox communicators."] if limit <= 0
      return [false, :unprocessable_entity, "Sandbox communicator limit reached."] if count >= limit

      [true, :ok, nil]
    end

    def check_slot_self_create(user, settings)
      limit = slot_limit_for(settings)
      count = owned_slot_count(user)

      return [false, :forbidden, "Your plan does not include communicator accounts."] if limit <= 0
      return [false, :unprocessable_entity, "Maximum number of communicator accounts reached."] if count >= limit

      [true, :ok, nil]
    end
  end
end
