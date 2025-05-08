class StripeClient
  def self.list_all_features
    features = Stripe::Entitlements::Feature.list({ limit: 3 })
  end

  def self.list_subscriptions_for_user(user_id)
    begin
      user = User.find(user_id)
      if user
        subscriptions = Stripe::Subscription.list({ customer: user.stripe_customer_id })
      else
        puts "User not found with ID: #{user_id}"
      end
    rescue StandardError => e
      puts "Error listing subscriptions: #{e.message}"
    end
    subscriptions
  end

  def self.assign_feature_to_user(user_id, feature_id, quantity)
    begin
      Stripe::Entitlements::FeatureAssignment.create({
        user: user_id,
        feature: feature_id,
        quantity: quantity,
      })
      puts "Feature #{feature_id} assigned to user #{user_id}."
    rescue Stripe::StripeError => e
      puts "Error assigning feature: #{e.message}"
    end
  end

  def self.add_commuicator_account(user_id, extra_communicators = 0)
    begin
      user = User.find(user_id)
      if user
        # Assuming you have a method to get the Stripe customer ID
        customer_id = user.stripe_customer_id
        user_subscriptions = user.get_stripe_subscriptions
        if user_subscriptions.blank?
          puts "No subscriptions found for user #{user_id}."
          return
        end
        if user_subscriptions.count > 1
          puts "Multiple subscriptions found for user #{user_id}. Please handle this case."
        end
        subscription = user_subscriptions.first
        match_subscription = true
        interval = subscription.items.data.first.plan.interval
        plan_id = nil
        if interval == "year"
          plan_id = user.pro? ? ENV["EXTRA_PRO_COMMUNICATOR_YEAR_PRICE_ID"] : ENV["EXTRA_BASIC_COMMUNICATOR_YEAR_PRICE_ID"]
        elsif interval == "month"
          plan_id = user.pro? ? ENV["EXTRA_PRO_COMMUNICATOR_MONTH_PRICE_ID"] : ENV["EXTRA_BASIC_COMMUNICATOR_MONTH_PRICE_ID"]
        else
          puts "Unknown subscription interval: #{interval}"
          return
        end
        if subscription && extra_communicators > 0
          subscription_items = subscription.items.data
          subscription_items.each do |item|
            updated_quantity = item.quantity + extra_communicators

            if item.price.id == plan_id
              match_subscription = true
              result = Stripe::SubscriptionItem.update(
                item.id,
                {
                  quantity: updated_quantity,
                #   proration_behavior: "create_prorations",
                }
              )

              user.settings["extra_communicators"] = updated_quantity
              user.save!
            else
              match_subscription = false
            end
          end
          unless match_subscription
            Stripe::SubscriptionItem.create(
              {
                subscription: subscription.id,
                price: plan_id,
                quantity: extra_communicators,
                proration_behavior: "create_prorations",
              }
            )

            user.settings["extra_communicators"] = extra_communicators
            user.save!
          end
        end
      else
        puts "User not found with ID: #{user_id}"
        return
      end
    rescue StandardError => e
      puts "Error adding extra communicators: #{e.message}"
      return
    end
    true
  end

  def self.create_pro_year_subscription(customer_id, extra_communicators = 0)
    base_price_id = ENV["PRO_YEAR_PLAN_PRICE_ID"]
    extra_pro_communicator_price_id = ENV["EXTRA_PRO_COMMUNICATOR_YEAR_PRICE_ID"]
    payload = {
      customer: customer_id,
      items: [
        {
          price: base_price_id,
          quantity: 1,
        },
        {
          price: extra_pro_communicator_price_id,
          quantity: extra_communicators,
        },
      ],
    }
    begin
      subscription = Stripe::Subscription.create(payload)
    rescue Stripe::StripeError => e
      puts "Error creating subscription: #{e.message}"
    end
  end

  def self.cancel_subscription(subscription_id)
    begin
      subscription = Stripe::Subscription.retrieve(subscription_id)
      subscription.delete
      puts "Subscription canceled successfully."
    rescue Stripe::StripeError => e
      puts "Error canceling subscription: #{e.message}"
    end
  end
end
