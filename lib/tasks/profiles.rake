namespace :profiles do
  # Migrate safety profile slugs to unguessable random tokens, preserving the
  # old slug as `legacy_slug` (the public endpoint 301-redirects old → new).
  #
  # Read-only by default (reports what would change). Apply with DRY_RUN=false.
  #
  #   rake profiles:migrate_to_random_slugs                 # preview
  #   DRY_RUN=false rake profiles:migrate_to_random_slugs   # apply
  #   DRY_RUN=false USER_ID=740 rake profiles:migrate_to_random_slugs
  desc "Migrate safety profile slugs to random tokens (DRY_RUN=false to apply; USER_ID=N to scope)"
  task migrate_to_random_slugs: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    user_id = ENV["USER_ID"].presence

    scope = Profile.where(profile_kind: "safety", slug_type: "legacy")
    if user_id
      child_ids = ChildAccount.where(user_id: user_id).pluck(:id)
      scope = scope.where(profileable_type: "ChildAccount", profileable_id: child_ids)
    end

    migrated_ids = []
    skipped = 0

    scope.find_each(batch_size: 100) do |profile|
      if dry_run
        puts "[DRY RUN] profile ##{profile.id} #{profile.slug.inspect} → random slug (old slug kept as legacy_slug)"
        migrated_ids << profile.id
        next
      end

      # update_columns skips validations + callbacks on purpose: the old slug
      # format won't survive the new ensure_slug logic, and we only touch
      # columns we control here.
      profile.update_columns(
        legacy_slug: profile.slug,
        slug: Profile.generate_random_slug,
        slug_type: "random",
        updated_at: Time.current,
      )
      migrated_ids << profile.id
    rescue => e
      Rails.logger.error("Failed to migrate profile #{profile.id}: #{e.message}")
      puts "  ! profile ##{profile.id} failed: #{e.message}"
      skipped += 1
    end

    if dry_run
      puts "Dry run only — #{migrated_ids.size} safety profile(s) would be migrated " \
           "and have their cards regenerated. Re-run with DRY_RUN=false to apply."
      next
    end

    puts "Migrated: #{migrated_ids.size}, Skipped: #{skipped}"

    # Only regenerate cards for the profiles migrated in THIS run, so a re-run
    # (or a USER_ID-scoped run) doesn't re-email parents whose cards are current.
    puts "Enqueueing safety-card regeneration..."
    migrated_ids.each { |id| RegenerateSafetyCardsJob.perform_later(id) }
    puts "Jobs enqueued: #{migrated_ids.size}"
  end
end
