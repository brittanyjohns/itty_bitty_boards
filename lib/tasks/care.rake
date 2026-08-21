# Migrating retired care options off the profiles that still hold them.
#
# Retiring an option is deliberately two steps (see
# Profile::DEPRECATED_CARE_OPTIONS): deprecate it so stored answers survive
# while the editor stops offering it, then run this to move those answers onto
# their replacements. Only once this reports zero remaining is it safe to delete
# the option from the constant — because sanitize_care_settings is a before_save
# and would otherwise erase the leftovers the next time anything saved a profile.
namespace :care do
  desc "Report profiles still holding retired care options (care:remap_options to fix)"
  task audit_options: :environment do
    counts = Hash.new(0)
    profiles = 0

    Profile.where.not(settings: nil).find_each do |profile|
      hits = CareOptionRemap.hits_for(profile)
      next if hits.empty?

      profiles += 1
      hits.each { |hit| counts[hit] += 1 }
    end

    if counts.empty?
      puts "No profile holds a retired care option. Safe to delete them from " \
           "Profile::DEPRECATED_CARE_OPTIONS."
      next
    end

    puts "#{profiles} profile(s) still hold retired options:"
    counts.sort_by { |_, n| -n }.each { |label, n| puts "  #{label}: #{n}" }
    puts "\nRun `rake care:remap_options DRY_RUN=false` to migrate them."
  end

  desc "Move retired care options onto their replacements (DRY_RUN=false to apply)"
  task remap_options: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    scope = Profile.where.not(settings: nil)
    scope = scope.where(id: ENV["PROFILE_ID"]) if ENV["PROFILE_ID"].present?

    changed = 0
    scope.find_each do |profile|
      care = profile.settings["care"]
      next unless care.is_a?(Hash)

      remapped = CareOptionRemap.apply(care)
      next unless remapped

      changed += 1
      if dry_run
        puts "would update profile #{profile.id} (#{profile.slug})"
      else
        # update_column, deliberately: a normal save would run
        # sanitize_care_settings, which is fine, but it would also fire the
        # profile's other callbacks (audio regeneration, safety-card renders)
        # on every row. This task changes stored option keys, nothing else.
        profile.update_column(:settings, profile.settings.merge("care" => remapped))
        puts "updated profile #{profile.id} (#{profile.slug})"
      end
    end

    puts dry_run ?
      "\nDRY RUN — #{changed} profile(s) would change. Re-run with DRY_RUN=false to apply." :
      "\nDone — #{changed} profile(s) updated."
  end

  # Repairing care text that was stored HTML-escaped. See CareTextRepair: the
  # cleaner used to persist "hugs &amp; quiet" for an ampersand a parent typed,
  # and a code fix alone leaves every already-saved row wrong until its owner
  # happens to edit that section again.
  desc "Report profiles holding HTML-escaped care text (care:unescape_text to fix)"
  task audit_escaped_text: :environment do
    counts = Hash.new(0)
    profiles = 0

    Profile.where.not(settings: nil).find_each do |profile|
      hits = CareTextRepair.hits_for(profile)
      next if hits.empty?

      profiles += 1
      puts "  profile #{profile.id} (#{profile.slug}): #{hits.join(", ")}"
      hits.each { |hit| counts[hit] += 1 }
    end

    if counts.empty?
      puts "No profile holds HTML-escaped care text."
      next
    end

    puts "\n#{profiles} profile(s) hold escaped care text, across #{counts.size} field(s)."
    puts "Run `rake care:unescape_text DRY_RUN=false` to fix them."
  end

  desc "Unescape HTML-escaped care text in place (DRY_RUN=false to apply)"
  task unescape_text: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    scope = Profile.where.not(settings: nil)
    scope = scope.where(id: ENV["PROFILE_ID"]) if ENV["PROFILE_ID"].present?

    changed = 0
    scope.find_each do |profile|
      care = profile.settings["care"]
      next unless care.is_a?(Hash)

      repaired = CareTextRepair.apply(care)
      next unless repaired

      changed += 1
      if dry_run
        puts "would update profile #{profile.id} (#{profile.slug}): " \
             "#{CareTextRepair.hits_for(profile).join(", ")}"
      else
        # update_column, for the same reason care:remap_options uses it: a
        # normal save would re-run sanitize_care_settings (harmless, and now
        # idempotent) but would also fire audio regeneration and safety-card
        # renders on every row. This task rewrites stored text, nothing else.
        profile.update_column(:settings, profile.settings.merge("care" => repaired))
        puts "updated profile #{profile.id} (#{profile.slug})"
      end
    end

    puts dry_run ?
      "\nDRY RUN — #{changed} profile(s) would change. Re-run with DRY_RUN=false to apply." :
      "\nDone — #{changed} profile(s) updated."
  end
  desc "Report profiles still holding detail lines on a BUILT-IN care section"
  task audit_items: :environment do
    # The editor stopped offering "+ Add a line" on built-in sections when
    # custom chips landed, but clean_builtin_care_section still ACCEPTS the rows
    # so nobody loses what they already wrote. Same two-step rule as
    # care:audit_options: only once this reports zero is it safe to delete the
    # clean_care_items call from clean_builtin_care_section — before that, the
    # before_save would erase every stored line on the next save of each row.
    #
    # Custom sections are excluded. Rows are still authored there, and that is
    # now the only place they are.
    counts = Hash.new(0)
    profiles = 0

    Profile.where.not(settings: nil).find_each do |profile|
      sections = profile.settings.dig("care", "sections")
      next unless sections.is_a?(Hash)

      held = sections.select do |key, section|
        Profile::CARE_SECTIONS.key?(key) && section.is_a?(Hash) && section["items"].present?
      end
      next if held.empty?

      profiles += 1
      held.each_key { |key| counts[key] += 1 }
    end

    if counts.empty?
      puts "No profile holds detail lines on a built-in section. Safe to drop " \
           "clean_care_items from Profile#clean_builtin_care_section."
      next
    end

    puts "#{profiles} profile(s) still hold built-in detail lines:"
    counts.sort_by { |_, n| -n }.each { |section, n| puts "  #{section}: #{n}" }
    puts "\nLeave clean_care_items wired up until this reports zero."
  end
end
