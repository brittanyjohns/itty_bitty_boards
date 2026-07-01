namespace :mailchimp do
  desc "Add ALL users to Mailchimp audience"
  task :add_all_users => :environment do
    puts "Enqueuing MailchimpUpsertSubscriberJob for all users..."
    User.find_each do |user|
      MailchimpUpsertSubscriberJob.perform_async(user.id)
      puts "Enqueued MailchimpUpsertSubscriberJob for user #{user.id} (#{user.email})"
    end
    puts "Done enqueuing MailchimpUpsertSubscriberJob for all users."
  end

  desc "Add users to Mailchimp audience"
  task :add_users, [:start, :limit] => :environment do |t, args|
    start = (args[:start] || 1).to_i
    limit = (args[:limit] || 100).to_i
    count = 0
    puts "Enqueuing MailchimpUpsertSubscriberJob for up to #{limit} users..."
    User.find_each(start: start, finish: start + limit - 1) do |user|
      begin
        MailchimpUpsertSubscriberJob.perform_async(user.id)
        # user.update_mailchimp_subscription
        puts "Enqueued MailchimpUpsertSubscriberJob for user #{user.id} (#{user.email})"
        count += 1
        break if count >= limit
      rescue => e
        puts "Failed to enqueue MailchimpUpsertSubscriberJob for user #{user.id} (#{user.email}): #{e.message}"
      end
    end
    puts "Done enqueuing MailchimpUpsertSubscriberJob for all users."
  end

  desc "Add single user to Mailchimp audience"
  task :add_user, [:user_id] => :environment do |t, args|
    user = User.find(args[:user_id])
    MailchimpUpsertSubscriberJob.perform_async(user.id)
    puts "Enqueued MailchimpUpsertSubscriberJob for user #{user.id} (#{user.email})"
  end

  # Re-enqueue DownloadLeads whose Mailchimp sync failed (mailchimp_status
  # "failed") — e.g. after fixing the contact data / audience config that
  # rejected them (the required-merge-field 400). Dry-run by default; set
  # DRY_RUN=false to actually reset status to "pending" and enqueue the job.
  # Scope to one address with EMAIL=someone@example.com.
  desc "Re-enqueue failed DownloadLead Mailchimp syncs (DRY_RUN=false to apply, EMAIL= to scope)"
  task :retry_failed_leads => :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    scope = DownloadLead.mailchimp_failed
    scope = scope.where(email: ENV["EMAIL"]) if ENV["EMAIL"].present?

    total = scope.count
    puts "Found #{total} failed lead(s)#{ENV["EMAIL"].present? ? " for #{ENV["EMAIL"]}" : ""}."
    if dry_run
      scope.find_each { |lead| puts "[dry-run] would re-enqueue lead #{lead.id} (#{lead.email})" }
      puts "Dry run — nothing enqueued. Re-run with DRY_RUN=false to apply."
    else
      count = 0
      scope.find_each do |lead|
        lead.update(mailchimp_status: DownloadLead::MAILCHIMP_PENDING)
        MailchimpUpsertLeadJob.perform_async(lead.id)
        count += 1
        puts "Re-enqueued lead #{lead.id} (#{lead.email})"
      end
      puts "Re-enqueued #{count} lead(s)."
    end
  end
end
