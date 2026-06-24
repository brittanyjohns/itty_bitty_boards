namespace :plans do
  # Keep ALL references to autoloaded constants (User::*_PLAN_LIMITS)
  # inside the task body. Rakefiles get loaded during asset precompile
  # before Rails boots — a top-level `User::FREE_PLAN_LIMITS` raises
  # `NameError: uninitialized constant User` during deploy.
  BACKFILL_LIMIT_KEYS = %w[paid_communicator_limit demo_communicator_limit board_limit].freeze

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
        # also run and overwrite the limit keys we just set.
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

  desc "One-off (2026-05-31): bump existing Pro users from 3 → 5 paid communicator slots. " \
       "Skips anyone an admin has tuned above 3 so we never lower a deliberate value."
  task bump_pro_to_five_communicators: :environment do
    dry_run = ENV["DRY_RUN"] == "true"
    bumped = 0
    skipped_higher = 0
    skipped_other = 0

    scope = User.where(plan_type: %w[pro pro_yearly partner_pro])

    puts "[bump_pro_to_five_communicators] starting (dry_run=#{dry_run}) — scope=#{scope.count} users"

    scope.find_each(batch_size: 200) do |user|
      user.settings ||= {}
      current = user.settings["paid_communicator_limit"].to_i

      if current > 3
        # Admin has already set something higher (e.g., 10). Don't touch it.
        skipped_higher += 1
        next
      end

      if current != 3 && current != 0
        # Anything other than 3 (or the missing-value sentinel 0) is unexpected
        # for a Pro user — log it and skip rather than silently overwrite.
        skipped_other += 1
        warn "[bump_pro_to_five_communicators] user #{user.id} has unexpected paid_communicator_limit=#{current.inspect} — skipping"
        next
      end

      if dry_run
        puts "  would bump user=#{user.id} plan=#{user.plan_type} #{current} → 5"
      else
        user.settings["paid_communicator_limit"] = 5
        # update_columns to skip callbacks — plan_type isn't changing,
        # so before_save :setup_limits should not re-run.
        user.update_columns(settings: user.settings, updated_at: Time.current)
      end
      bumped += 1
      print "." if !dry_run && bumped % 100 == 0
    rescue => e
      skipped_other += 1
      warn "[bump_pro_to_five_communicators] user #{user.id} failed: #{e.message}"
    end

    puts
    puts "[bump_pro_to_five_communicators] done. bumped=#{bumped} " \
         "skipped_higher=#{skipped_higher} skipped_other=#{skipped_other}"
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

  desc "Migrate users on the retired basic_trial soft-trial tier to the free plan " \
       "(drafts/drop-basic-trial-option-a.md). Mirrors DowngradeSoftTrialJob so " \
       "credits/limits/boards land cleanly."
  task migrate_basic_trial_to_free: :environment do
    migrated = 0
    skipped = 0

    User.where(plan_type: "basic_trial").find_each do |user|
      user.setup_free_limits
      user.plan_type = "free"
      user.plan_status = "active"
      user.plan_expires_at = nil
      user.settings ||= {}
      user.settings["plan_nickname"] = "free"
      user.save!

      # Re-grant the free-tier allowance so they don't see balance=0 after
      # losing the 400-credit trial grant (mirrors DowngradeSoftTrialJob).
      CreditService.grant_plan!(
        user,
        amount: CreditService.monthly_credits_for("free"),
        period_end: CreditService.initial_period_end_for("free"),
        metadata: { source: "basic_trial_migration" },
      )

      # Pin a default editable board so over-limit boards have a deterministic
      # editable slot (matches DowngradeSoftTrialJob / apply_free_plan).
      user.pin_default_editable_board!
      migrated += 1
      print "." if migrated % 100 == 0
    rescue => e
      skipped += 1
      warn "[plans:migrate_basic_trial_to_free] user #{user.id} failed: #{e.message}"
    end

    puts "\nMigration complete. migrated=#{migrated} skipped=#{skipped}"
  end

  # One-off recovery for users stranded by the paused-subscription webhook gap
  # (PR fixing handle_subscription_upsert). The webhook fix only prevents NEW
  # strandings — users already in the bad state need this reconcile.
  #
  # A "stranded" user has a non-paying plan_status (UNPAID_STATUSES: canceled,
  # paused, incomplete_expired, unpaid) while plan_type is still a paid tier.
  # They were never properly downgraded to free, so paid_plan? is false (no paid
  # features) yet RefreshFreeTierCreditsJob skips them and no invoice fires —
  # they sit at 0 credits indefinitely.
  #
  # This is STATE-based, not cause-based: it heals every stranded user (paused,
  # canceled, lapsed, etc.) regardless of which webhook race put them there.
  # apply_free_plan keeps the existing status reason, grants the free allowance,
  # pins an editable board, and clears stripe_subscription_id. Naturally
  # idempotent — once a user is free they no longer match the scope.
  #
  # Defaults to DRY RUN. Apply with: DRY_RUN=false bin/rails plans:reconcile_stranded_paid
  task reconcile_stranded_paid: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    # Paid tiers that should never coexist with an unpaid status. basic_trial is
    # excluded (handled by DowngradeSoftTrialJob); free/nil are already correct.
    scope = User
      .where(plan_status: User::UNPAID_STATUSES)
      .where.not(plan_type: ["free", "basic_trial", nil])

    total = scope.count
    puts "[plans:reconcile_stranded_paid] dry_run=#{dry_run} stranded_users=#{total}"

    reconciled = 0
    failed = 0

    scope.find_each(batch_size: 200) do |user|
      puts "  user=#{user.id} email=#{user.email} plan_type=#{user.plan_type} " \
           "plan_status=#{user.plan_status} plan_credits=#{user.plan_credits_balance}"
      next if dry_run

      Billing::PlanTransitions.apply_free_plan(user, user.plan_status)
      reconciled += 1
    rescue => e
      failed += 1
      warn "[plans:reconcile_stranded_paid] user #{user.id} failed: #{e.class} #{e.message}"
    end

    if dry_run
      puts "\nDRY RUN — no changes written. Re-run with DRY_RUN=false to apply."
    else
      puts "\nReconcile complete. reconciled=#{reconciled} failed=#{failed}"
    end
  end
end
