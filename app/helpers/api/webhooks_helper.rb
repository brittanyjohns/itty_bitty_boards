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
    else
      "free"
    end
  end

  def self.get_communicator_limit(plan_type_name)
    return 0 if plan_type_name.blank? || plan_type_name.include?("free")
    plan_name = plan_type_name.downcase.split("_").first
    initial_comm_account_limit = plan_type_name.split("_").second || 1
    if initial_comm_account_limit.to_i == 0
      initial_comm_account_limit = nil
    end

    if plan_name.include?("basic")
      initial_comm_account_limit = 1
    elsif plan_name.include?("pro")
      initial_comm_account_limit = 3
    elsif plan_name.include?("plus")
      initial_comm_account_limit = 5
    elsif plan_name.include?("premium")
      initial_comm_account_limit = 10
    elsif plan_name.include?("myspeak")
      initial_comm_account_limit = 1
    else
      # Free plan or unknown plan
      initial_comm_account_limit = 0
    end
    initial_comm_account_limit.to_i
  end

  def self.get_board_limit(plan_type_name)
    return 0 if plan_type_name.nil?
    plan_name = plan_type_name.downcase.split("_").first
    initial_comm_account_limit = get_communicator_limit(plan_type_name)
    if plan_name.include?("basic")
      initial_comm_account_limit * 25
    elsif plan_name.include?("pro")
      initial_comm_account_limit * 25
    elsif plan_name.include?("plus")
      initial_comm_account_limit * 25
    elsif plan_name.include?("premium")
      initial_comm_account_limit * 25
    else
      # Free & myspeak plans
      3
    end
  end
end
