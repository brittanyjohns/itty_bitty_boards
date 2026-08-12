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
end
