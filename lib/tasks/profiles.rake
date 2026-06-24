namespace :profiles do
  desc "Migrate safety profile slugs to random tokens (preserves old slug as legacy_slug)"
  task migrate_to_random_slugs: :environment do
    migrated = 0
    skipped = 0

    Profile.where(profile_kind: "safety", slug_type: "legacy").find_each(batch_size: 100) do |profile|
      # update_columns skips validations + callbacks on purpose: the old slug
      # format won't survive the new ensure_slug logic, and we only touch
      # columns we control here.
      profile.update_columns(
        legacy_slug: profile.slug,
        slug: Profile.generate_random_slug,
        slug_type: "random",
        updated_at: Time.current,
      )
      migrated += 1
    rescue => e
      Rails.logger.error("Failed to migrate profile #{profile.id}: #{e.message}")
      skipped += 1
    end

    puts "Migrated: #{migrated}, Skipped: #{skipped}"

    puts "Enqueueing safety-card regeneration..."
    enqueued = 0
    Profile.where(slug_type: "random").find_each(batch_size: 100) do |profile|
      RegenerateSafetyCardsJob.perform_later(profile.id)
      enqueued += 1
    end
    puts "Jobs enqueued: #{enqueued}"
  end
end
