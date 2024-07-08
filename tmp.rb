# stripe trigger customer.subscription.created \
#         --override product:name=foo \
#         --override price:unit_amount=4200

def trigger_customer_subscription_created
  puts "Customer subscription created"
  `stripe trigger customer.subscription.created \
        --override product:name=foo \
        --override price:unit_amount=4200`
end

trigger_customer_subscription_created
puts "Done"
