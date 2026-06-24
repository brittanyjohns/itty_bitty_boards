namespace :communicators do
  # Backfill for the create-path fix: before this, a Free user's self-created
  # communicator (generic form OR MySpeak onboarding wizard) was created as a
  # full `active` login account instead of a no-login sandbox. This converts
  # those stray self-creates to sandbox so they render as "MySpeak Free
  # accounts" and stop offering sign-in.
  #
  # SAFE BY DESIGN: only touches comms owned by a Free user that were never
  # claimed (claimed_at IS NULL). A claimed/hand-off communicator keeps its
  # login — those are exactly the ones a Free family is meant to sign into — so
  # claimed_at-present comms are skipped.
  #
  # Dry-run by default. Apply with DRY_RUN=false:
  #   rake communicators:convert_free_self_created_to_sandbox            # preview
  #   DRY_RUN=false rake communicators:convert_free_self_created_to_sandbox
  desc "Convert Free users' never-claimed active/loaner self-creates to no-login sandbox (DRY_RUN=false to apply)"
  task convert_free_self_created_to_sandbox: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    free_user_ids = User.where(plan_type: "free").select(:id)
    scope = ChildAccount
      .where(status: [ChildAccount::ACTIVE, ChildAccount::LOANER])
      .where(claimed_at: nil)
      .where(owner_id: free_user_ids)

    total = scope.count
    puts "#{dry_run ? '[DRY RUN] ' : ''}#{total} communicator(s) to convert to sandbox"

    converted = 0
    scope.find_each do |ca|
      puts "  ##{ca.id} #{ca.name.inspect} (owner #{ca.owner_id}) #{ca.status} -> sandbox"
      unless dry_run
        ca.update!(status: ChildAccount::SANDBOX, passcode: nil)
        converted += 1
      end
    end

    if dry_run
      puts "Dry run only — re-run with DRY_RUN=false to apply."
    else
      puts "Converted #{converted} communicator(s) to sandbox."
    end
  end

  # Backfill for issue #359: a paid user (Basic/Pro) whose communicator was
  # created while they were still Free is stuck in sandbox mode with sign-in
  # disabled. The forward fix (User#reconcile_paid_sandbox_promotions!) only
  # runs when plan_type changes, so existing affected users need this one-off.
  #
  # Promotes each affected paid user's sandbox communicators to full `active`
  # accounts, most-recently-active first, up to their available paid slots —
  # exactly what the upgrade callback now does. promote_to_active! mints a
  # passcode so sign-in works and lifts the sandbox board cap. Idempotent.
  #
  # Scoped to plans with ZERO sandbox entitlement (Basic). Pro grants 1 sandbox
  # slot, so Pro users' sandboxes are intentional scratch/demo accounts and are
  # left untouched. Admins skipped (unlimited; already sign in to any account).
  #
  # Dry-run by default. Apply with DRY_RUN=false. Optionally scope to one user:
  #   rake communicators:promote_paid_sandboxes                       # preview all
  #   DRY_RUN=false rake communicators:promote_paid_sandboxes         # apply all
  #   DRY_RUN=false USER_ID=740 rake communicators:promote_paid_sandboxes
  desc "Promote paid users' stuck sandbox communicators to full active (DRY_RUN=false to apply; USER_ID=N to scope)"
  task promote_paid_sandboxes: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    users = ENV["USER_ID"].present? ? User.where(id: ENV["USER_ID"]) : User.all
    promoted = 0
    affected_users = 0

    users.find_each do |user|
      next if user.admin? || !user.paid_plan?
      # Plans that grant any sandbox slot (Pro) keep their intentional sandboxes.
      next if Permissions::CommunicatorLimits.sandbox_limit_for(user.settings || {}) > 0

      slot_limit = Permissions::CommunicatorLimits.slot_limit_for(user.settings || {})
      available = slot_limit - Permissions::CommunicatorLimits.owned_slot_count(user)
      next if available <= 0

      sandboxes = user.communicator_accounts
        .where(status: ChildAccount::SANDBOX)
        .order(Arel.sql("last_sign_in_at DESC NULLS LAST, updated_at DESC, id DESC"))
        .limit(available)
        .to_a
      next if sandboxes.empty?

      affected_users += 1
      sandboxes.each do |ca|
        puts "#{dry_run ? '[DRY RUN] ' : ''}user #{user.id} (#{user.plan_type}): communicator ##{ca.id} #{ca.name.inspect} sandbox -> active"
        unless dry_run
          ca.promote_to_active!
          promoted += 1
        end
      end
    end

    if dry_run
      puts "Dry run only — re-run with DRY_RUN=false to apply."
    else
      puts "Promoted #{promoted} communicator(s) across #{affected_users} user(s)."
    end
  end

  # Repair for the handoff team-membership bug: `ChildAccount#claim_by!`
  # used to act on `teams.first`, which is unreliable when a communicator
  # belongs to more than one team. The hand-off could update the wrong
  # team, leaving the communicator's OWN team (the "<name>'s Communication
  # Team" auto-created at creation) with stale membership — the new owner
  # missing, the previous owner still admin, and team ownership unchanged.
  #
  # For each already-claimed (active) communicator this:
  #   - pins settings["primary_team_id"] to the own team,
  #   - adds the current owner as `admin`,
  #   - transfers team ownership (created_by) to the current owner so they
  #     get is_owner / can_invite,
  #   - demotes the team's previous creator (the lending SLP) to
  #     `supervisor` — matching what claim_by! now does going forward.
  #
  # Conservative: only acts when the communicator's OWN team is
  # identifiable (pinned id, namesake name, or the team where this
  # communicator is the only account). A communicator that only appears on
  # a shared team is skipped and logged, so we never hijack someone else's
  # team. Idempotent.
  #
  # Dry-run by default. Apply with DRY_RUN=false. Optionally scope to one
  # owner with USER_ID=N:
  #   rake communicators:repair_handoff_teams                    # preview all
  #   DRY_RUN=false rake communicators:repair_handoff_teams      # apply all
  #   DRY_RUN=false USER_ID=740 rake communicators:repair_handoff_teams
  desc "Repair stale handoff team membership/ownership on claimed communicators (DRY_RUN=false to apply; USER_ID=N to scope)"
  task repair_handoff_teams: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    scope = ChildAccount
      .where(status: ChildAccount::ACTIVE)
      .where.not(claimed_at: nil)
      .where.not(owner_id: nil)
    scope = scope.where(owner_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    repaired = 0
    skipped = 0

    scope.find_each do |ca|
      owner = ca.owner
      next if owner.nil?

      team = handoff_repair_own_team(ca)
      if team.nil?
        skipped += 1
        puts "#{dry_run ? '[DRY RUN] ' : ''}communicator ##{ca.id} #{ca.name.inspect} (owner #{owner.id}) — SKIP: no own team identifiable"
        next
      end

      previous_creator_id = team.created_by_id
      actions = []
      actions << "pin primary_team=#{team.id}" if ca.settings&.dig("primary_team_id") != team.id

      owner_tu = team.team_users.find_by(user_id: owner.id)
      actions << (owner_tu ? "owner #{owner.id} #{owner_tu.role}->admin" : "add owner #{owner.id} as admin") if owner_tu&.role != "admin"

      actions << "transfer team owner #{previous_creator_id}->#{owner.id}" if previous_creator_id != owner.id

      demote_id = (previous_creator_id != owner.id) ? previous_creator_id : nil
      if demote_id
        demote_tu = team.team_users.find_by(user_id: demote_id)
        actions << "prev owner #{demote_id} #{demote_tu&.role || 'none'}->supervisor" if demote_tu&.role != "supervisor"
      end

      if actions.empty?
        puts "#{dry_run ? '[DRY RUN] ' : ''}communicator ##{ca.id} #{ca.name.inspect} (team ##{team.id}) — already correct"
        next
      end

      puts "#{dry_run ? '[DRY RUN] ' : ''}communicator ##{ca.id} #{ca.name.inspect} (team ##{team.id} #{team.name.inspect}): #{actions.join('; ')}"

      unless dry_run
        ActiveRecord::Base.transaction do
          ca.pin_primary_team!(team)
          team.upsert_member!(owner, "admin")
          team.upsert_member!(User.find_by(id: demote_id), "supervisor") if demote_id
          team.update!(created_by_id: owner.id) if previous_creator_id != owner.id
        end
        repaired += 1
      end
    end

    if dry_run
      puts "Dry run only (#{skipped} skipped) — re-run with DRY_RUN=false to apply."
    else
      puts "Repaired #{repaired} communicator(s); skipped #{skipped}."
    end
  end
end

# Resolve a communicator's OWN team for the handoff repair, conservatively.
# Returns the pinned team, else the namesake team, else the single team
# where this communicator is the only account, else nil (do not guess).
def handoff_repair_own_team(child_account)
  pinned_id = child_account.settings&.dig("primary_team_id")
  if pinned_id
    pinned = child_account.teams.find_by(id: pinned_id)
    return pinned if pinned
  end

  namesake = child_account.namesake_team
  return namesake if namesake

  child_account.teams.find { |team| team.account_ids == [child_account.id] }
end
