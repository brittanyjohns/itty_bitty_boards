namespace :partners do
  # Read-only snapshot of where every Partner Pro pilot sits relative to its
  # 3-month window. Mirrors the categories PartnerPilotEndingJob acts on so you
  # can see who's ending soon / already ended without waiting for the daily
  # digest. Changes nothing — safe to run any time.
  #
  #   bin/rails partners:pilot_status
  #   PARTNER_PILOT_REMINDER_LEAD_DAYS=21 bin/rails partners:pilot_status
  desc "List Partner Pro pilots by expiry status (read-only)"
  task pilot_status: :environment do
    lead_days = (ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"] || 14).to_i
    now = Time.current
    cutoff = now + lead_days.days

    partners = User.where(plan_type: "partner_pro")
    with_date = partners.where.not(plan_expires_at: nil)

    expired = with_date.where("plan_expires_at <= ?", now).order(:plan_expires_at)
    ending_soon = with_date.where("plan_expires_at > ? AND plan_expires_at <= ?", now, cutoff).order(:plan_expires_at)
    active = with_date.where("plan_expires_at > ?", cutoff).order(:plan_expires_at)
    no_date = partners.where(plan_expires_at: nil).order(:created_at)

    print_group = lambda do |label, scope|
      puts "\n#{label} (#{scope.size})"
      puts("-" * 60)
      scope.each do |u|
        ends = u.plan_expires_at&.strftime("%Y-%m-%d") || "—"
        flags = []
        flags << "reminded" if u.settings.is_a?(Hash) && u.settings["partner_pilot_ending_notified"]
        flags << "expired-flagged" if u.settings.is_a?(Hash) && u.settings["partner_pilot_expired"]
        suffix = flags.any? ? "  [#{flags.join(', ')}]" : ""
        puts "  ##{u.id}  #{u.email.ljust(34)}  ends #{ends}#{suffix}"
      end
    end

    puts "\n=== Partner Pro pilot status (lead window: #{lead_days} days) ==="
    puts "Total partner_pro: #{partners.size}"
    print_group.call("🔔 ENDED (needs review — not downgraded)", expired)
    print_group.call("⏳ ENDING SOON (within #{lead_days} days)", ending_soon)
    print_group.call("✅ ACTIVE (beyond lead window)", active)
    print_group.call("❔ NO plan_expires_at set", no_date)
    puts
  end

  # Backfill: grant the Partner Pro (Pro-equivalent) credit allowance to any
  # partner_pro user still sitting below it — the cohort created before the
  # signup-time grant fix, who got the free allowance instead of 1500.
  # Dry-run by default (reports only); apply with DRY_RUN=false. Scope to one
  # user with USER_ID=N.
  #
  #   bin/rails partners:grant_pro_credits              # dry run
  #   DRY_RUN=false bin/rails partners:grant_pro_credits
  desc "Grant the Pro-equivalent credit allowance to under-granted Partner Pro users"
  task grant_pro_credits: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    allowance = CreditService.monthly_credits_for("partner_pro")

    scope = User.where(plan_type: "partner_pro")
    scope = scope.where(id: ENV["USER_ID"]) if ENV["USER_ID"].present?
    shorted = scope.where("plan_credits_balance < ?", allowance)

    puts "\n=== partners:grant_pro_credits (#{dry_run ? 'DRY RUN' : 'APPLYING'}) ==="
    puts "Partner Pro allowance: #{allowance}"
    puts "Under-granted partner_pro users: #{shorted.count}\n\n"

    granted = 0
    shorted.find_each do |user|
      puts "  ##{user.id}  #{user.email.ljust(34)}  #{user.plan_credits_balance.to_i} -> #{allowance}"
      next if dry_run

      CreditService.grant_plan!(
        user,
        amount: allowance,
        period_end: CreditService.initial_period_end_for("partner_pro"),
        metadata: { source: "partner_pro_backfill", plan_type: "partner_pro" },
      )
      granted += 1
    rescue => e
      puts "    !! failed for ##{user.id}: #{e.message}"
    end

    puts "\n#{dry_run ? 'Would grant' : 'Granted'} #{dry_run ? shorted.count : granted} user(s)."
    puts "Re-run with DRY_RUN=false to apply.\n\n" if dry_run
  end
end
