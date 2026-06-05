# Drop the no-CC `basic_trial` (Option A)

**Decision:** Remove the no-credit-card soft trial. Every new signup starts on
**Free**. The only trial is the existing CC-required Stripe trial (14 days, card
on file). Existing `basic_trial` users are **migrated to Free immediately**.

**Why:** We were giving away two free periods that stacked — 14 days of no-CC
Basic (`basic_trial`) *plus* the 14-day CC Stripe trial — so a patient signup
could get ~28 days of premium-level access before the first charge. Removing
`basic_trial` leaves exactly one free path (the Free tier) and one trial (the CC
Stripe trial). Loophole closed; first revenue moment moves up.

**Not doing now:** charging immediately on the Stripe trial (the CC trial is
intentional) and the money-back guarantee.

---

## Scope: this is small, not a refactor

New signups get bumped into `basic_trial` from exactly two places. Neutralize
those, migrate the current trial users, and leave the rest of the `basic_trial`
plumbing in place as harmless fallback (so no straggler hits a 402). Dead-code
cleanup is a follow-up, not part of this change.

---

## Backend changes

### 1. `app/models/user.rb` — stop minting new `basic_trial` users

Today (line ~173):

```ruby
before_create :set_soft_trial_plan, if: :free_trial?
```

`set_soft_trial_plan` (line ~204) sets `plan_type = "basic_trial"` for new users
and applies Basic limits. Replace the soft-trial bump with a free-plan setup so
new users land on Free with the correct limits:

- Remove the `before_create :set_soft_trial_plan` callback.
- Add a `before_create` that ensures Free limits are applied on signup, e.g.
  `setup_free_limits` + `ensure_minimum_communicator_slot!`. (The `plan_type`
  column already defaults to `"free"`; we just need the limits/credit setup that
  `set_soft_trial_plan` used to trigger.)
- Leave `set_soft_trial_plan` defined but unused for now (or delete it — it has
  no other callers once the auths-controller block below is removed).

> Verify at implementation time that a brand-new Free user gets `FREE_PLAN_LIMITS`
> applied and a 5-credit initial grant (`after_create :grant_initial_plan_credits`
> already fires; confirm it reads `free`, not `basic_trial`).

### 2. `app/controllers/api/v1/auths_controller.rb` — remove the login-time re-apply

Delete the block at lines ~64–68:

```ruby
if user.free_trial? && user.plan_type != "basic_trial"
  user.set_soft_trial_plan
  Rails.logger.info "..."
  user.save!
end
```

This is what re-bumps a within-14-days Free user back into `basic_trial` on
login. With it gone, a Free user stays Free.

### 3. Migrate existing `basic_trial` users to Free now

Add a one-off rake task modeled on the existing `plans:migrate_myspeak_to_free`.
It mirrors `DowngradeSoftTrialJob` so credits/limits/boards land cleanly:

```ruby
desc "Migrate users on the retired basic_trial soft-trial tier to the free plan"
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
    user.pin_default_editable_board!
    migrated += 1
    print "." if migrated % 100 == 0
  rescue => e
    skipped += 1
    warn "[plans:migrate_basic_trial_to_free] user #{user.id} failed: #{e.message}"
  end

  puts "\nMigration complete. migrated=#{migrated} skipped=#{skipped}"
end
```

Run with `DRY_RUN` support if you want a count first (optional — the myspeak
task doesn't have one). Run on production after the code deploy lands.

### 4. Leave as-is (harmless fallback, clean up later)

- `CreditService::PLAN_MONTHLY_CREDITS["basic_trial"]` (400) and
  `INITIAL_PERIOD_DAYS["basic_trial"]` (14)
- `setup_limits` `basic_trial` branch
- `RefreshFreeTierCreditsJob::REFRESHABLE_PLAN_TYPES` includes `basic_trial`
- `DowngradeSoftTrialJob` — keep it running; once the migration empties the
  `basic_trial` cohort it's a no-op and acts as a backstop.

Keeping these means any account that somehow still reads `basic_trial` degrades
gracefully instead of 402-ing.

---

## Tests to update

- `spec/models/user_spec.rb` — `basic_trial` / `set_soft_trial_plan` expectations
- `spec/models/user_lifecycle_spec.rb`
- `spec/requests/lifecycle_integration_spec.rb`
- `spec/requests/api/profiles_spec.rb`
- `spec/factories.rb` and `spec/support/credits_helper.rb` — any default that
  assumes new users are `basic_trial`
- `spec/sidekiq/downgrade_soft_trial_job_spec.rb` — still valid (job still runs)
- New: a spec asserting a fresh signup lands on `free` with Free limits + 5 credits

---

## Follow-up cleanup (separate PR, not blocking)

- Frontend trial UI that references `basic_trial` / trial-days-left:
  `itty-bitty-frontend/src/pages/Welcome.tsx`,
  `src/components/utils/UserHome.tsx`, `src/data/users.ts`, `src/data/utils.ts`
- Once the `basic_trial` cohort is confirmed empty, strip the `basic_trial`
  branches from `CreditService`, `setup_limits`, `RefreshFreeTierCreditsJob`,
  `plans.rake`, and retire `DowngradeSoftTrialJob` + `set_soft_trial_plan`.

---

## Rollout order

1. Merge backend change (stop minting + Free-on-signup).
2. Deploy.
3. Run `bin/rails plans:migrate_basic_trial_to_free` on production.
4. Spot-check: a new signup shows Free (1 board, 1 communicator, 1 MySpeak demo,
   5 credits); a previously-`basic_trial` user now shows Free with a non-zero
   balance.
5. Schedule the frontend + dead-code cleanup PR.
