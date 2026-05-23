namespace :plans do
  # Keep ALL references to autoloaded constants (User::*_PLAN_LIMITS)
  # inside the task body. Rakefiles get loaded during asset precompile
  # before Rails boots — a top-level `User::FREE_PLAN_LIMITS` raises
  # `NameError: uninitialized constant User` during deploy.
  BACKFILL_LIMIT_KEYS = %w[paid_communicator_limit demo_communicator_limit board_limit ai_monthly_limit].freeze

  desc "Backfill per-tier limits onto user.settings, filling missing/zero values without clobbering admin-tuned higher values"
  task backfill_communicator_limits: :environment do
    # Built at task-execution time (after :environment), so User is
    # available. partner_pro and basic_trial inherit their paid tier's
    # slot math (matches User#setup_limits).
    limits_by_plan = {
      "free"         => User::FREE_PLAN_LIMITS,
      "basic"        => User::BASIC_PLAN_LIMITS,
      "basic_yearly" => User::BASIC_PLAN_LIMITS,
      "basic_trial"  => User::BASIC_PLAN_LIMITS,
      "pro"          => User::PRO_PLAN_LIMITS,
      "pro_yearly"   => User::PRO_PLAN_LIMITS,
      "partner_pro"  => User::PRO_PLAN_LIMITS,
    }.freeze

    dry_run = ENV["DRY_RUN"] == "true"
    only_plans = ENV["PLANS"]&.split(",")&.map(&:strip)
    updated = 0
    unchanged = 0
    skipped = 0
    by_plan = Hash.new(0)

    scope = User.all
    scope = scope.where(plan_type: only_plans) if only_plans

    puts "[backfill_communicator_limits] starting (dry_run=#{dry_run} plans=#{only_plans || "all"})"

    scope.find_each(batch_size: 200) do |user|
      defaults = limits_by_plan[user.plan_type]
      unless defaults
        skipped += 1
        next
      end

      user.settings ||= {}
      changes = {}

      BACKFILL_LIMIT_KEYS.each do |key|
        current = user.settings[key].to_i
        # Fill when missing or explicitly 0 — never clobber a higher
        # value an admin set intentionally.
        if current <= 0 && defaults[key].to_i > 0
          changes[key] = defaults[key]
        end
      end

      if changes.empty?
        unchanged += 1
        next
      end

      by_plan[user.plan_type] += 1

      if dry_run
        puts "  would update user=#{user.id} plan=#{user.plan_type} changes=#{changes.inspect}"
        updated += 1
      else
        user.settings.merge!(changes)
        # update_columns to skip callbacks — the plan_type isn't
        # changing, and we don't want before_save :setup_limits to
        # also run and overwrite ai_monthly_limit etc.
        user.update_columns(settings: user.settings, updated_at: Time.current)
        updated += 1
        print "." if updated % 100 == 0
      end
    rescue => e
      skipped += 1
      warn "[plans:backfill_communicator_limits] user #{user.id} failed: #{e.message}"
    end

    puts
    puts "[backfill_communicator_limits] done. updated=#{updated} unchanged=#{unchanged} skipped=#{skipped}"
    by_plan.sort.each { |plan, count| puts "  #{plan}: #{count}" }
    puts "(dry run — no rows were written)" if dry_run
  end

  desc "Migrate users on the retired MySpeak plan tier to the free plan"
  task migrate_myspeak_to_free: :environment do
    migrated = 0
    skipped = 0

    User.where(plan_type: %w[myspeak myspeak_yearly]).find_each do |user|
      user.plan_type = "free"
      user.plan_status = "active"
      user.plan_expires_at = nil
      user.paid_plan_type = nil if user.paid_plan_type.to_s.include?("myspeak")
      user.settings ||= {}
      user.settings["plan_nickname"] = "free"
      # plan_type changed -> before_save :setup_limits applies the free-plan
      # limits (which now include one demo-communicator slot).
      user.save!
      migrated += 1
      print "." if migrated % 100 == 0
    rescue => e
      skipped += 1
      warn "[plans:migrate_myspeak_to_free] user #{user.id} failed: #{e.message}"
    end

    puts "\nMigration complete. migrated=#{migrated} skipped=#{skipped}"
    if migrated.positive?
      puts "Plan credits self-heal: migrated users have no Stripe subscription, " \
           "so RefreshFreeTierCreditsJob (daily) re-grants the free-tier allowance."
    end
  end
end
