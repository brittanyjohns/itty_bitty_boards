namespace :billing do
  desc "Stamp settings['billing_provider'] = 'revenuecat' on App Store subscribers from before the " \
       "RevenueCat webhook wrote it, so User#billing_source can tell them from admin comps. " \
       "Dry-run by default. ENV: APPLY=1 to write. " \
       "Usage: bin/rails billing:stamp_revenuecat_provider APPLY=1"
  task stamp_revenuecat_provider: :environment do
    apply = ENV["APPLY"].to_s == "1"
    provider = RevenueCat::WebhookProcessor::PROVIDER

    # Paid with no Stripe subscription is the set billing_source can't place on
    # its own: an App Store subscriber and an admin comp look identical there.
    # A Stripe subscriber is already answered by its subscription id.
    candidates = User
      .where(stripe_subscription_id: [nil, ""])
      .where.not(plan_type: [nil, "", "free"])

    checked = 0
    stamped = 0

    candidates.find_each do |user|
      next if user.admin? || !user.paid_plan?
      next if user.settings.to_h["billing_provider"].present?

      checked += 1

      # The credit ledger remembers who granted the plan. The monthly refresh
      # grant (RefreshFreeTierCreditsJob) carries no provider, so it is skipped;
      # every other grant answers the question — a RevenueCat purchase says
      # revenuecat, and the free-plan grant a lapse writes says the App Store
      # stopped billing, so a lapsed-then-comped account is correctly left alone.
      latest = user.credit_transactions
                   .where(kind: "plan_grant")
                   .where("metadata->>'source' IS DISTINCT FROM 'refresh_credits_job'")
                   .order(created_at: :desc, id: :desc)
                   .first
      next unless latest && latest.metadata.to_h["provider"] == provider

      stamped += 1
      puts "#{apply ? "stamping" : "would stamp"} user=#{user.id} plan_type=#{user.plan_type}"
      next unless apply

      # update_column: a backfill must not run plan-change callbacks.
      user.update_column(:settings, user.settings.to_h.merge("billing_provider" => provider))
    end

    puts ""
    puts "checked #{checked} paid account(s) with no Stripe subscription; " \
         "#{apply ? "stamped" : "would stamp"} #{stamped} account(s)."
    puts(apply ? "APPLIED." : "Dry run — re-run with APPLY=1 to write.")
  end
end
