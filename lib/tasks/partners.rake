namespace :partners do
  # One-time "restart everyone brand new": put an explicit set of partners onto
  # a fresh no-card Stripe trial (Phase 2), regardless of their current state
  # (free / pro / partner_pro, with or without a stale subscription). For each
  # id in IDS:
  #   1. Cancel + clear any existing Stripe subscription (e.g. the leftover $0
  #      "free" subs some downgraded partners still carry) so the fresh trial
  #      isn't skipped by ensure_partner_pro_trial_subscription!'s guard.
  #   2. Set a staggered trial_end (now + MONTHS + index*STAGGER_DAYS) so the
  #      partner_pilot_wrap nudges ~3 months out don't all fire the same day.
  #   3. Run the standard partner onboarding (handle_new_partner_pro_subscription):
  #      resets plan_type=partner_pro + limits + 1500 credits, creates the fresh
  #      trial subscription, pre-seeds the welcome guard, and re-tags Mailchimp
  #      "Partner Program" + the monthly cohort so the journey can fire.
  #
  # IDS is REQUIRED and explicit (comma-separated) — no role-based default, so a
  # stray run can't touch test/demo accounts. Dry-run by default.
  #
  #   IDS=244,258,419 bin/rails partners:restart                 # dry run
  #   IDS=244,258,419 MONTHS=3 STAGGER_DAYS=1 DRY_RUN=false bin/rails partners:restart
  desc "Restart specific partners on a fresh no-card Stripe trial (IDS=required, dry-run default)"
  task restart: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    months = (ENV["MONTHS"] || 3).to_i
    stagger = (ENV["STAGGER_DAYS"] || 1).to_i

    ids = ENV["IDS"].to_s.split(",").map { |s| s.strip.to_i }.reject(&:zero?)
    abort "IDS is required (e.g. IDS=244,258 bin/rails partners:restart)" if ids.empty?

    users = User.where(id: ids).order(:id).to_a
    missing = ids - users.map(&:id)
    puts "\n=== partners:restart (#{dry_run ? 'DRY RUN' : 'APPLYING'}) ==="
    puts "Requested: #{ids.size}  Found: #{users.size}#{missing.any? ? "  Missing: #{missing.join(', ')}" : ''}"
    puts "Trial length: #{months} months, staggered +#{stagger} day(s) per partner\n\n"

    base = Time.current
    done = 0
    users.each_with_index do |user, i|
      trial_end = base + months.months + (i * stagger).days
      label = "##{user.id}  #{user.email.to_s.ljust(36)}"
      old = "#{user.plan_type}/#{user.plan_status}"
      sub_note = user.stripe_subscription_id.present? ? "cancel #{user.stripe_subscription_id}" : "no existing sub"
      puts "#{label}  #{old} -> partner_pro/trialing  ends #{trial_end.strftime('%Y-%m-%d')}  (#{sub_note})"
      next if dry_run

      begin
        # 1. Cancel + clear any existing subscription so the fresh trial is created.
        if user.stripe_subscription_id.present?
          begin
            Stripe::Subscription.cancel(user.stripe_subscription_id)
          rescue Stripe::InvalidRequestError => e
            Rails.logger.warn "[PartnerRestart] cancel #{user.stripe_subscription_id} for ##{user.id}: #{e.message}"
          end
          user.update_columns(stripe_subscription_id: nil)
        end

        # 2. Clear pilot flags + prior welcome guard so this is a clean slate,
        #    and set the staggered end date (handle_new_... keeps a non-nil one).
        %w[partner_pilot_ending_notified partner_pilot_expired partner_pilot_expired_at
           plan_welcome_sent_for].each { |k| user.settings.delete(k) }
        user.plan_type = "partner_pro"
        user.plan_expires_at = trial_end
        user.save!

        # 3. Standard partner onboarding: fresh trial sub + credits + Mailchimp tags.
        User.handle_new_partner_pro_subscription(user, "partner_pro")
        done += 1
      rescue => e
        puts "   !! failed for ##{user.id}: #{e.class} - #{e.message}"
      end
    end

    puts "\n#{dry_run ? 'Would restart' : 'Restarted'} #{dry_run ? users.size : done} partner(s)."
    puts "Re-run with DRY_RUN=false to apply.\n\n" if dry_run
  end

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

  # Extend a partner pilot by N months (default 3). Moves BOTH the local
  # plan_expires_at and the Stripe subscription's trial_end so Stripe re-arms
  # the trial_will_end reminder and the auto-cancel. Extends from the later of
  # "now" and the current plan_expires_at, so an already-expired pilot gets a
  # fresh full window and an active one is pushed further out. Dry-run by
  # default; apply with DRY_RUN=false. Requires USER_ID=N.
  #
  #   USER_ID=42 bin/rails partners:extend                 # dry run, +3 months
  #   USER_ID=42 MONTHS=6 DRY_RUN=false bin/rails partners:extend
  desc "Extend a Partner Pro pilot (local plan_expires_at + Stripe trial_end)"
  task extend: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    months = (ENV["MONTHS"] || 3).to_i

    user_id = ENV["USER_ID"]
    abort "USER_ID is required (e.g. USER_ID=42 bin/rails partners:extend)" if user_id.blank?

    user = User.find_by(id: user_id)
    abort "No user with id=#{user_id}" if user.nil?
    unless user.plan_type == "partner_pro"
      abort "User ##{user.id} (#{user.email}) is not on partner_pro (plan_type=#{user.plan_type})"
    end

    base = [Time.current, user.plan_expires_at].compact.max
    new_end = base + months.months

    puts "\n=== partners:extend (#{dry_run ? 'DRY RUN' : 'APPLYING'}) ==="
    puts "  User:        ##{user.id}  #{user.email}"
    puts "  Current end: #{user.plan_expires_at&.strftime('%Y-%m-%d') || '—'}"
    puts "  New end:     #{new_end.strftime('%Y-%m-%d')} (+#{months} month(s))"
    puts "  Stripe sub:  #{user.stripe_subscription_id.presence || '(none — local plan_expires_at only)'}"

    if dry_run
      puts "\nRe-run with DRY_RUN=false to apply.\n\n"
    else
      user.extend_partner_pro_trial!(new_end: new_end)
      # Clear the once-flags so a re-extended pilot can be reminded/flagged again.
      user.settings.delete("partner_pilot_ending_notified")
      user.settings.delete("partner_pilot_expired")
      user.settings.delete("partner_pilot_expired_at")
      user.save!
      puts "\nExtended. plan_expires_at is now #{user.reload.plan_expires_at.strftime('%Y-%m-%d')}.\n\n"
    end
  end

  # Partner fold (hard deadline Oct 14, 2026): convert every `partner_pro` user
  # to the free `clinician` plan. Run MANUALLY after the licenses+clinicians PR
  # merges, before the live partner no-card trials auto-convert (Oct 14–20).
  #
  # Per user:
  #   1. Flip plan_type -> clinician FIRST (local save; setup_clinician_limits +
  #      reconcile callbacks run). Doing this before the Stripe cancel means the
  #      `customer.subscription.deleted` webhook — which fires when we cancel the
  #      old trial below — hits the already-clinician guard in
  #      API::WebhooksController#handle_subscription_deleted and no-ops, so the
  #      partner is never dumped onto Free (downgrades retain, never delete).
  #   2. role == "partner" keeps 5 loaner slots (settings override of the
  #      clinician 2-slot cap; PARTNER_LOANER_SLOTS, default 5), then reconcile so
  #      any communicators that now fit come back out of fallback.
  #   3. Grant the clinician credit allowance (400) — clinician is free / no
  #      Stripe invoice, so credits are granted synchronously here (same pattern
  #      as the partner_pro comp grant).
  #   4. Cancel + clear the old partner_pro no-card Stripe trial.
  #
  # Idempotent by construction: the scope is plan_type=partner_pro, so a
  # re-run skips everyone already folded to clinician. Dry-run by default; apply
  # with DRY_RUN=false. Scope to one user with USER_ID=N.
  #
  #   bin/rails partners:fold_into_clinicians                 # dry run
  #   DRY_RUN=false bin/rails partners:fold_into_clinicians
  desc "Fold all partner_pro users into the free clinician plan (dry-run default)"
  task fold_into_clinicians: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    partner_loaner_slots = (ENV["PARTNER_LOANER_SLOTS"] || 5).to_i

    scope = User.where(plan_type: "partner_pro")
    scope = scope.where(id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    puts "\n=== partners:fold_into_clinicians (#{dry_run ? 'DRY RUN' : 'APPLYING'}) ==="
    puts "partner_pro users: #{scope.count}   (role=partner keep #{partner_loaner_slots} loaner slots)\n\n"

    folded = 0
    scope.find_each do |user|
      keep_slots = user.role == "partner"
      slots = keep_slots ? partner_loaner_slots : User::CLINICIAN_PLAN_LIMITS["paid_communicator_limit"]
      sub_note = user.stripe_subscription_id.present? ? "cancel #{user.stripe_subscription_id}" : "no sub"
      puts "  ##{user.id}  #{user.email.to_s.ljust(34)}  partner_pro -> clinician  slots=#{slots}  (#{sub_note})"
      next if dry_run

      begin
        # 1. Flip to clinician first so the webhook guard protects the cancel.
        user.plan_type = "clinician"
        user.plan_status = "active"
        user.save!

        # 2. Partners keep their loaner slots; re-reconcile at the new limit.
        if keep_slots
          user.settings["paid_communicator_limit"] = partner_loaner_slots
          user.save!
          user.reconcile_communicator_fallback!
        end

        # 3. Clinician credit allowance (free plan, no invoice — grant now).
        CreditService.grant_plan!(
          user,
          amount: CreditService.monthly_credits_for("clinician"),
          period_end: CreditService.initial_period_end_for("clinician"),
          metadata: { source: "partner_fold", plan_type: "clinician" },
        )

        # 4. Cancel + clear the old partner_pro no-card Stripe trial. The webhook
        #    guard no-ops for the now-clinician user, so this can't drop them.
        if user.stripe_subscription_id.present?
          begin
            Stripe::Subscription.cancel(user.stripe_subscription_id)
          rescue Stripe::InvalidRequestError => e
            Rails.logger.warn "[Fold] cancel #{user.stripe_subscription_id} for ##{user.id}: #{e.message}"
          end
          user.update_columns(stripe_subscription_id: nil)
        end

        folded += 1
      rescue => e
        puts "     !! failed for ##{user.id}: #{e.class} - #{e.message}"
      end
    end

    puts "\n#{dry_run ? 'Would fold' : 'Folded'} #{dry_run ? scope.count : folded} partner(s) into clinician."
    puts "Re-run with DRY_RUN=false to apply.\n\n" if dry_run
  end

  # One-off: (re)record existing partners in Mailchimp with the stable
  # "Partner Program" trigger tag plus their monthly PartnerPro_<Month> cohort
  # tag. Needed because the signup-time tagging call was broken (passed a String
  # where a User was expected), so partners created before that fix likely have
  # no Mailchimp record — and thus can't enter the Partner Customer Journey.
  # Dry-run by default (reports only); apply with DRY_RUN=false. Scope to one
  # user with USER_ID=N.
  #
  # NOTE: if the journey is already live, backfilled partners enter at step 1 —
  # fine for a relaunch, but they'll get the sequence fresh.
  #
  #   bin/rails partners:backfill_mailchimp_tags              # dry run
  #   DRY_RUN=false bin/rails partners:backfill_mailchimp_tags
  desc "Tag existing partners in Mailchimp with the stable 'Partner Program' trigger tag"
  task backfill_mailchimp_tags: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    scope = User.where(role: "partner")
    scope = scope.where(id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    puts "\n=== partners:backfill_mailchimp_tags (#{dry_run ? 'DRY RUN' : 'APPLYING'}) ==="
    puts "Partners (role: partner): #{scope.count}\n\n"

    tagged = 0
    scope.find_each do |user|
      tags = ["Partner Program", user.get_partner_group]
      puts "  ##{user.id}  #{user.email.ljust(34)}  tags #{tags}"
      next if dry_run

      MailchimpService.new.record_new_subscriber(user, tags: tags)
      tagged += 1
    rescue => e
      puts "    !! failed for ##{user.id}: #{e.message}"
    end

    puts "\n#{dry_run ? 'Would tag' : 'Tagged'} #{dry_run ? scope.count : tagged} partner(s)."
    puts "Re-run with DRY_RUN=false to apply.\n\n" if dry_run
  end
end
