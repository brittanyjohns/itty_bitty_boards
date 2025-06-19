module API::WebhooksHelper
  def self.get_plan_type(plan)
    return "free" if plan.nil?
    if plan.include?("basic")
      "basic"
    elsif plan.include?("pro")
      "pro"
    elsif plan.include?("plus")
      "plus"
    elsif plan.include?("myspeak")
      "myspeak"
    elsif plan.include?("premium")
      "premium"
      # elsif plan.include?("vendor")
      #   "vendor"
    elsif plan.include?("free")
      "free"
    else
      Rails.logger.debug "Unknown plan type: #{plan}"
      "free"
    end
  end

  def self.get_communicator_limit(plan_type)
    Rails.logger.debug "Determining communicator limit for plan type: #{plan_type}"
    if plan_type.include?("basic")
      # Basic plan has a default of 1 communicator account
      initial_comm_account_limit = 1
    elsif plan_type.include?("pro")
      initial_comm_account_limit = 3
    elsif plan_type.include?("plus")
      initial_comm_account_limit = 5
    elsif plan_type.include?("premium")
      initial_comm_account_limit = 10
    elsif plan_type.include?("myspeak")
      initial_comm_account_limit = 1
    else
      # Free plan or unknown plan
      initial_comm_account_limit = 0
    end
    Rails.logger.debug "Returning communicator limit: #{initial_comm_account_limit}"
    initial_comm_account_limit.to_i
  end

  def self.get_user_role(plan_type)
    return "free" if plan_type.nil?
    role = plan_type.downcase.split("_").first
    if role.include?("vendor")
      "vendor"
    else
      "user"
    end
  end

  def self.get_board_limit(comm_account_limit, user_role)
    return 0 if comm_account_limit.nil? || comm_account_limit <= 0
    if user_role == "vendor"
      comm_account_limit * 3
    else
      comm_account_limit * 25
    end
  end
end
