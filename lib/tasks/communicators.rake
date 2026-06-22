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
  # Promotes each paid user's sandbox communicators to full `active` accounts,
  # most-recently-active first, up to their available paid slots — exactly what
  # the upgrade callback now does. promote_to_active! mints a passcode so
  # sign-in works and lifts the sandbox board cap. Idempotent. Admins skipped
  # (unlimited; already sign in to any account).
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
end
