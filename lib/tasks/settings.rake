namespace :settings do
  # Junk keys that leaked into user.settings via the old
  # API::UsersController#update_settings, which blindly persisted every request
  # param (Rails adds controller/action/id/format; wrap_parameters mirrors the
  # body under `user`). None are real settings.
  JUNK_SETTINGS_KEYS = %w[controller action id format user].freeze

  # Keys that used to be written but are no longer read by any code path.
  #   ai_monthly_limit — AI is gated by the credit ledger (CreditService) now;
  #                       this was never read on the enforcement path.
  DEAD_SETTINGS_KEYS = %w[ai_monthly_limit].freeze

  desc "Scrub junk + dead keys (controller/action/id/format/user, ai_monthly_limit) from user.settings. DRY_RUN=false to apply, USER_ID=N to scope."
  task cleanup: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    only_user_id = ENV["USER_ID"].presence

    removable = (JUNK_SETTINGS_KEYS + DEAD_SETTINGS_KEYS).freeze
    updated = 0
    unchanged = 0
    skipped = 0
    removed_by_key = Hash.new(0)

    scope = User.all
    scope = scope.where(id: only_user_id) if only_user_id

    puts "[settings:cleanup] starting (dry_run=#{dry_run} user_id=#{only_user_id || "all"})"
    puts "[settings:cleanup] removable keys: #{removable.join(", ")}"

    scope.find_each(batch_size: 200) do |user|
      settings = user.settings
      unless settings.is_a?(Hash)
        skipped += 1
        next
      end

      present = removable.select { |key| settings.key?(key) }
      if present.empty?
        unchanged += 1
        next
      end

      present.each { |key| removed_by_key[key] += 1 }

      if dry_run
        puts "  would clean user=#{user.id} plan=#{user.plan_type} remove=#{present.inspect}"
        updated += 1
      else
        cleaned = settings.except(*removable)
        # update_columns to skip callbacks — we're only removing dead/junk keys,
        # not changing plan state, and don't want before_save :setup_limits etc.
        user.update_columns(settings: cleaned, updated_at: Time.current)
        updated += 1
        print "." if updated % 100 == 0
      end
    rescue => e
      skipped += 1
      warn "[settings:cleanup] user #{user.id} failed: #{e.message}"
    end

    puts
    puts "[settings:cleanup] done. updated=#{updated} unchanged=#{unchanged} skipped=#{skipped}"
    removed_by_key.sort.each { |key, count| puts "  #{key}: #{count}" }
    puts "[settings:cleanup] DRY RUN — re-run with DRY_RUN=false to apply." if dry_run
  end
end
