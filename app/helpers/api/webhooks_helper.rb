module API::WebhooksHelper
  def self.get_plan_type(plan)
    return "free" if plan.nil?
    if plan.include?("basic")
      "basic"
    elsif plan.include?("pro")
      "pro"
    elsif plan.include?("plus")
      "plus"
    else
      "free"
    end
  end

  def self.get_communicator_limit(plan_type_name)
    return 0 if plan_type_name.blank? || plan_type_name.include?("free")
    plan_name = plan_type_name.downcase.split("_").first
    comm_account_limit = plan_type_name.split("_").second || 1
    if comm_account_limit.to_i == 0
      comm_account_limit = nil
    end

    if plan_name.include?("basic")
      comm_account_limit = 1
    elsif plan_name.include?("pro")
      comm_account_limit = 3
    elsif plan_name.include?("plus")
      comm_account_limit = 5
    elsif plan_name.include?("premium")
      comm_account_limit = 10
    else
      comm_account_limit = 0
    end
    comm_account_limit.to_i
  end

  def self.get_board_limit(plan_type_name)
    return 0 if plan_type_name.nil?
    plan_name = plan_type_name.downcase.split("_").first
    comm_account_limit = get_communicator_limit(plan_type_name)
    if plan_name.include?("basic")
      comm_account_limit * 25
    elsif plan_name.include?("pro")
      comm_account_limit * 25
    elsif plan_name.include?("plus")
      comm_account_limit * 25
    elsif plan_name.include?("premium")
      comm_account_limit * 25
    else
      0
    end
  end
end
