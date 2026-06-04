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
end
