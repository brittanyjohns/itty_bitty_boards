class API::ChargesController < API::ApplicationController
  def new
  end

  def create
    # Amount in cents
    @amount = current_order.subtotal

    customer = Stripe::Customer.create email: params[:"cardholder-email"],
                                       :source => params[:stripeToken]

    charge = Stripe::Charge.create(
      :customer => customer.id,
      :amount => (@amount * 100).to_i,
      :description => "Waroong Stripe customer",
      :currency => "usd",
    )

    user_session['order_id'] = nil
  rescue Stripe::CardError => e
    flash[:notice] = e.message
    redirect_to new_charge_path
  end
end
