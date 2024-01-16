class CartsController < ApplicationController
  before_action :authenticate_user!
  ONE_DOLLAR_PRICE_ID = ENV['ONE_DOLLAR_PRICE_ID']
  DOMAIN = ENV['DOMAIN'] || 'http://localhost:3000'

  def show
    @current_order = current_order
    puts "user_session: #{user_session.inspect}"
    raise "No order found" unless @current_order

    puts "Current order: #{@current_order.inspect}"
    @order_items = @current_order.order_items
    @amount = @current_order.total
    puts "amount: #{@amount.to_i}"
    @stripe_customer_id = current_user.stripe_customer_id
    puts "stripe_customer_id: #{@stripe_customer_id}"
    current_user.set_payment_processor :stripe
    @checkout_session = current_user.payment_processor.checkout_charge(
      amount: 100,
      name: "One-time payment for #{current_user.email}",
      currency: "usd",
      quantity: @amount.to_i,
      success_url: DOMAIN + '/success',
      cancel_url: DOMAIN + '/cancel'
    )
    puts "checkout_session: #{@checkout_session}"
      # mode: "payment", line_items: ONE_DOLLAR_PRICE_ID, quantity: @amount.to_i, success_url: DOMAIN + '/success', cancel_url: DOMAIN + '/cancel')
    current_user.stripe_customer_id = @checkout_session.customer
    current_user.save!
    puts "checkout_session: #{@checkout_session}"
  end

end
