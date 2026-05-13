namespace :credits do
  desc "Backfill an initial plan credit grant for every user based on their plan_type"
  task backfill: :environment do
    granted = 0
    skipped = 0
    User.find_each do |user|
      next skipped += 1 if CreditTransaction.where(user_id: user.id, kind: "plan_grant").exists?

      plan_type = user.plan_type.presence || "free"
      amount = CreditService.monthly_credits_for(plan_type)
      candidate = user.plan_expires_at
      period_end = (candidate.present? && candidate > Time.current) ? candidate : 30.days.from_now

      CreditService.grant_plan!(
        user,
        amount: amount,
        period_end: period_end,
        metadata: { reason: "phase1_backfill", plan_type: plan_type },
      )
      granted += 1
      print "." if granted % 100 == 0
    end
    puts "\nBackfill complete. granted=#{granted} skipped=#{skipped}"
  end

  desc "Re-grant plan credits to users zeroed out by the stale-plan_expires_at backfill bug (issue #110)"
  task regrant_stale_backfill: :environment do
    regranted = 0
    skipped = 0

    affected_user_ids = CreditTransaction
      .where(kind: "expire", source: "plan")
      .where("metadata->>'reason' = ?", "period_ended")
      .distinct.pluck(:user_id)

    User.where(id: affected_user_ids, plan_credits_balance: 0).find_each do |user|
      unless CreditTransaction.exists?(user_id: user.id, kind: "plan_grant")
        skipped += 1
        next
      end

      plan_type = user.plan_type.presence || "free"
      amount = CreditService.monthly_credits_for(plan_type)
      CreditService.grant_plan!(
        user,
        amount: amount,
        period_end: 30.days.from_now,
        metadata: { reason: "manual_regrant_stale_plan_expires_at", plan_type: plan_type },
      )
      regranted += 1
    end

    puts "Re-grant complete. regranted=#{regranted} skipped=#{skipped}"
  end

  desc "Recompute denormalized balances from the credit_transactions ledger"
  task recompute_balances: :environment do
    fixed = 0
    User.find_each do |user|
      plan = user.credit_transactions.where(source: "plan").sum(:amount)
      topup = user.credit_transactions.where(source: "topup").sum(:amount)
      if user.plan_credits_balance != plan || user.topup_credits_balance != topup
        user.update_columns(
          plan_credits_balance: [plan, 0].max,
          topup_credits_balance: [topup, 0].max,
        )
        fixed += 1
      end
    end
    puts "Balances recomputed. fixed=#{fixed}"
  end
end
