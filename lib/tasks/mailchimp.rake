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

  # Recovery for a user whose hit_limit dedupe key got stamped while the
  # journey couldn't actually send (older code stamped on enqueue). Clearing
  # the key lets the email fire again the next time they trip the board cap.
  desc "Clear the hit_limit journey dedupe key for a user"
  task :clear_hit_limit_dedupe, [:user_id] => :environment do |t, args|
    user_id = args[:user_id]
    if user_id.blank?
      puts "Usage: bin/rails 'mailchimp:clear_hit_limit_dedupe[USER_ID]'"
      next
    end

    key = "mailchimp:hit_limit:#{user_id}"
    if Rails.cache.delete(key)
      puts "Cleared #{key}"
    else
      puts "No dedupe key found at #{key} (nothing to clear)"
    end
  end
end
