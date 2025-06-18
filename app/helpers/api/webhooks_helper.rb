module API::WebhooksHelper
  def self.get_plan_type(plan)
    puts "get_plan_type: #{plan}"
    return "free" if plan.nil?
    if plan.include?("basic")
      puts "Basic plan detected"
      "basic"
    elsif plan.include?("pro")
      puts "Pro plan detected"
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
      puts "Unknown plan detected"
      "free"
    end
  end

  def self.get_communicator_limit(plan_type)
    # puts "get_communicator_limit: #{plan_type}"
    # return 0 if plan_type.blank? || plan_type.include?("free")
    # plan_type = plan_type.downcase.split("_").first
    # puts "plan_type: #{plan_type}"
    # initial_comm_account_limit = plan_type.split("_").second || 1
    # puts "initial_comm_account_limit: #{initial_comm_account_limit}"
    # if initial_comm_account_limit.to_i == 0
    #   initial_comm_account_limit = nil
    # end
    # puts "final initial_comm_account_limit: #{initial_comm_account_limit}"

    if plan_type.include?("basic")
      # Basic plan has a default of 1 communicator account
      puts "Basic plan detected"
      initial_comm_account_limit = 1
    elsif plan_type.include?("pro")
      initial_comm_account_limit = 3
    elsif plan_type.include?("plus")
      initial_comm_account_limit = 5
    elsif plan_type.include?("premium")
      initial_comm_account_limit = 10
    elsif plan_type.include?("myspeak")
      initial_comm_account_limit = 1
      # elsif plan_type.include?("vendor")
      #   initial_comm_account_limit = 1
    else
      # Free plan or unknown plan
      puts "Free or unknown plan detected"
      initial_comm_account_limit = 0
    end
    puts "Returning communicator limit: #{initial_comm_account_limit}"
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

  def self.get_board_limit(plan_type, user_role)
    return 0 if plan_type.nil?
    # plan_type = plan_type.downcase.split("_").first
    if user_role == "vendor"
      puts "Vendor role detected"
      if plan_type.include?("basic")
        initial_board_limit_limit = 3
      elsif plan_type.include?("pro")
        initial_board_limit_limit = 10
      elsif plan_type.include?("plus")
        initial_board_limit_limit = 50
      elsif plan_type.include?("premium")
        initial_board_limit_limit = 100
      else
        # Free plans
        initial_board_limit_limit = 1
      end
      return initial_board_limit_limit
    end
    puts "get_board_limit: #{plan_type}, initial_board_limit_limit: #{initial_board_limit_limit}"
    if plan_type.include?("basic")
      initial_board_limit_limit * 25
    elsif plan_type.include?("pro")
      initial_board_limit_limit * 25
    elsif plan_type.include?("plus")
      initial_board_limit_limit * 25
    elsif plan_type.include?("premium")
      initial_board_limit_limit * 25
    else
      # Free & myspeak plans
      3
    end
  end
end
