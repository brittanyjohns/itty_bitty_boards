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
end
