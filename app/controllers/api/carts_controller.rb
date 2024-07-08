class API::CartsController < API::ApplicationController
  before_action :authenticate_user!
  DOMAIN = ENV["DOMAIN"] || "http://localhost:4000"

  def show
    @current_order = current_order
    raise "No order found" unless @current_order

    @order_items = @current_order.order_items
    redirect_to root_path, notice: "Your cart is empty" if @order_items.empty?

    @amount = @current_order.total
    @stripe_customer_id = current_user.stripe_customer_id
    current_user.set_payment_processor :stripe
    if @amount > 0
      @checkout_session = current_user.payment_processor.checkout_charge(
        amount: 100,
        name: "One-time payment for #{current_user.email}",
        currency: "usd",
        quantity: @amount.to_i,
        success_url: DOMAIN + "/success",
        cancel_url: DOMAIN + "/cancel",
      )
      current_user.stripe_customer_id = @checkout_session.customer
      current_user.save!
    end
  end
end
