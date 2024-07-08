class CreateSubscriptionJob
  include Sidekiq::Job

  def perform(subscription_data)
    begin
      puts "Creating subscription from data: #{subscription_data}"
      parsed_data = JSON.parse(subscription_data)
      subscription = Subscription.build_from_stripe_event(parsed_data)
      subscription.save!
    rescue => e
      puts "Error creating subscription: #{e.inspect}\n #{e.backtrace}"
    end
  end
end
