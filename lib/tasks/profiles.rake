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

  # One-time cleanup for the About Me / emergency notes split.
  #
  # Before the split, MySpeak onboarding wrote its care/emergency notes into
  # `bio` (the PUBLIC About Me). This copies that text into the PRIVATE
  # `settings["emergency_notes"]` (behind the gated safety_view reveal) for
  # child-account safety profiles whose emergency notes are still blank. Bio
  # is KEPT — no public page goes blank; the parent can then edit both fields
  # from the new editors. Idempotent (re-run skips profiles already set) and
  # skips the generated placeholder bios.
  #
  # Read-only by default (reports what would change). Apply with DRY_RUN=false.
  #
  #   rake profiles:copy_onboarding_bio_to_emergency_notes                 # preview
  #   DRY_RUN=false rake profiles:copy_onboarding_bio_to_emergency_notes   # apply
  #   DRY_RUN=false USER_ID=740 rake profiles:copy_onboarding_bio_to_emergency_notes
  desc "Copy onboarding bios into blank emergency_notes for safety profiles (DRY_RUN=false to apply; USER_ID=N to scope)"
  task copy_onboarding_bio_to_emergency_notes: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    user_id = ENV["USER_ID"].presence

    # Generated placeholder bios (Profile#set_defaults and the placeholder
    # factories) are not real About Me text — never migrate them.
    default_bios = [
      "Write a short bio about yourself. This will help others understand who you are and what you do.",
      "This is a placeholder profile waiting to be claimed. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
    ].freeze

    scope = Profile.where(profile_kind: "safety", profileable_type: "ChildAccount")
    if user_id
      child_ids = ChildAccount.where(user_id: user_id).pluck(:id)
      scope = scope.where(profileable_id: child_ids)
    end

    copied = 0
    skipped = 0

    scope.find_each(batch_size: 100) do |profile|
      bio = profile.bio.to_s.strip
      raw = profile.settings.is_a?(Hash) ? profile.settings : {}

      # Skip: no real bio, a generated default, or emergency notes already set.
      if bio.blank? || default_bios.include?(bio) || raw["emergency_notes"].present?
        skipped += 1
        next
      end

      if dry_run
        puts "[DRY RUN] profile ##{profile.id} #{profile.slug.inspect} → copy bio into emergency_notes"
        copied += 1
        next
      end

      new_settings = raw.merge("emergency_notes" => bio)
      profile.update_columns(settings: new_settings, updated_at: Time.current)
      copied += 1
    rescue => e
      Rails.logger.error("Failed to copy bio→emergency_notes for profile #{profile.id}: #{e.message}")
      puts "  ! profile ##{profile.id} failed: #{e.message}"
      skipped += 1
    end

    if dry_run
      puts "Dry run only — #{copied} profile(s) would get bio copied into emergency_notes " \
           "(#{skipped} skipped). Re-run with DRY_RUN=false to apply."
      next
    end

    puts "Copied: #{copied}, Skipped: #{skipped}"
  end
end
