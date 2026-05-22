namespace :plans do
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
