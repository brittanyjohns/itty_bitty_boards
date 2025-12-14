module Permissions
  module CommunicatorLimits
    module_function

    # Returns: [allowed(Boolean), status(Symbol), error_message(String|nil)]
    def can_create?(user:, is_demo:)
      return [false, :unauthorized, "Unauthorized"] unless user

      settings = user.settings || {}

      if is_demo
        demo_limit = (settings["demo_communicator_limit"] || 1).to_i
        demo_count = user.demo_communicator_accounts.count

        return [false, :forbidden, "Your plan does not include demo communicators."] if demo_limit <= 0
        return [false, :unprocessable_entity, "Demo communicator limit reached."] if demo_count >= demo_limit

        return [true, :ok, nil]
      end

      comm_limit = (settings["paid_communicator_limit"] || 0).to_i
      real_count = user.paid_communicator_accounts.count

      return [false, :forbidden, "Your plan does not include communicator accounts."] if comm_limit <= 0
      return [false, :unprocessable_entity, "Maximum number of communicator accounts reached."] if real_count >= comm_limit

      [true, :ok, nil]
    end
  end
end
