require "csv"

# Phase 1 of the beta-end sweep (.claude-notes/beta-end-founding-rate-handoff.md).
# READ-ONLY: compares every user's persisted settings limits and actual usage
# against the entitlement for their plan_type. Phase 2 (beta:end_beta) is only
# built/run if this audit finds over-entitled users.
namespace :beta do
  desc "Read-only audit: persisted limits + actual usage vs. plan entitlement. Writes tmp/beta_audit_<date>.csv, no DB writes."
  task audit_entitlements: :environment do
    csv_path = ENV["BETA_AUDIT_CSV"].presence ||
      Rails.root.join("tmp", "beta_audit_#{Date.current.strftime("%Y-%m-%d")}.csv").to_s

    # Mirrors User#setup_limits' plan_type → limits routing. Unknown/blank
    # plan types get the Free entitlement, matching how enforcement falls
    # back (User#board_limit etc. default to FREE_PLAN_LIMITS).
    entitlement_for = lambda do |plan_type|
      case plan_type.to_s
      when "basic", "basic_yearly", "basic_trial"
        ["basic", User::BASIC_PLAN_LIMITS]
      when "pro", "pro_yearly", "partner_pro"
        ["pro", User::PRO_PLAN_LIMITS]
      when "free"
        ["free", User::FREE_PLAN_LIMITS]
      else
        ["free (fallback)", User::FREE_PLAN_LIMITS]
      end
    end

    # Same counting rules as the enforcement paths:
    #   boards — User#countable_board_count (own, non-template, non-predefined,
    #            non-builder_child)
    #   communicators — Permissions::CommunicatorLimits.owned_slot_count
    #            (owned loaner + active)
    board_counts = Board.where(is_template: false, predefined: false)
      .not_builder_child.group(:user_id).count
    slot_counts = ChildAccount
      .where(status: [ChildAccount::LOANER, ChildAccount::ACTIVE])
      .group(:owner_id).count

    scanned = 0
    flagged_rows = []
    over_settings_by_plan = Hash.new(0)
    over_usage_by_plan = Hash.new(0)
    exempt_flagged = 0
    unknown_plan_types = Hash.new(0)

    User.find_each do |user|
      scanned += 1
      settings = user.settings || {}
      plan = user.plan_type.to_s
      entitlement_plan, entitled = entitlement_for.call(plan)
      unknown_plan_types[plan] += 1 if entitlement_plan == "free (fallback)"

      board_limit_setting = settings["board_limit"]
      # Effective persisted slot limit, exactly as enforcement reads it
      # (communicator_slot_limit overrides paid_communicator_limit).
      communicator_limit_setting = Permissions::CommunicatorLimits.slot_limit_for(settings)

      board_count = board_counts[user.id].to_i
      communicator_count = slot_counts[user.id].to_i

      over_settings =
        (board_limit_setting.present? && board_limit_setting.to_i > entitled["board_limit"]) ||
        communicator_limit_setting > entitled["paid_communicator_limit"]
      over_usage =
        board_count > entitled["board_limit"] ||
        communicator_count > entitled["paid_communicator_limit"]

      next unless over_settings || over_usage

      # Reconciliation (phase 2) must not touch admin/partner accounts —
      # surface them in the CSV but keep them out of the actionable counts.
      exempt =
        if user.admin?
          "admin"
        elsif plan == "partner_pro" || user.role == "partner"
          "partner_pro"
        end

      if exempt
        exempt_flagged += 1
      else
        over_settings_by_plan[plan.presence || "(blank)"] += 1 if over_settings
        over_usage_by_plan[plan.presence || "(blank)"] += 1 if over_usage
      end

      flagged_rows << [
        user.id, user.email, plan, exempt, entitlement_plan,
        board_limit_setting, entitled["board_limit"],
        communicator_limit_setting, entitled["paid_communicator_limit"],
        board_count, communicator_count,
        over_settings, over_usage,
      ]
    end

    FileUtils.mkdir_p(File.dirname(csv_path))
    CSV.open(csv_path, "w") do |csv|
      csv << %w[
        user_id email plan_type exempt entitlement_plan
        board_limit_setting board_limit_entitled
        communicator_limit_setting communicator_limit_entitled
        board_count communicator_count
        over_settings over_usage
      ]
      flagged_rows.each { |row| csv << row }
    end

    summary = lambda do |counts|
      counts.empty? ? "none" : counts.sort.map { |plan, n| "#{plan}=#{n}" }.join(" ")
    end

    puts "Scanned #{scanned} users."
    puts "Over-entitled settings by plan: #{summary.call(over_settings_by_plan)}"
    puts "Over actual usage by plan: #{summary.call(over_usage_by_plan)}"
    puts "Exempt (admin/partner_pro) flagged: #{exempt_flagged}"
    unless unknown_plan_types.empty?
      puts "Unknown plan_type values (audited against Free entitlement): #{summary.call(unknown_plan_types)}"
    end
    puts "CSV: #{csv_path} (#{flagged_rows.size} flagged users)"
    puts "No writes performed."
  end
end
