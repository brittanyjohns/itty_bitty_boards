class API::CheckoutsController < API::ApplicationController
  def new
    @current_order = current_order
    # @payment_intent = current_user.payment_processor.create_payment_intent(1000)

    # @client_secret = @payment_intent.client_secret
    # @client_token = gateway.client_token.generate
    @amount = @current_order.total if @current_order
    
  end

  def show
    # @transaction = gateway.transaction.find(params[:id])
    # @result = _create_result_hash(@transaction)
    @order = current_user.orders.placed.last
  end
  YOUR_DOMAIN = 'http://localhost:4000'
  ONE_DOLLAR_PRICE_ID = ENV['ONE_DOLLAR_PRICE_ID']

  def create
    @current_order = current_order
    @amount = @current_order.total if @current_order
    raise "No order found" unless @current_order
    # amount = params["amount"] # In production you should not take amounts directly from clients
    nonce = params["payment_method_nonce"]

    quantity = @amount.to_i
    session = Stripe::Checkout::Session.create({
      line_items: [{
        # Provide the exact Price ID (e.g. pr_1234) of the product you want to sell
        price: ONE_DOLLAR_PRICE_ID,
        quantity: quantity,
      }],
      mode: 'payment',
      success_url: YOUR_DOMAIN + '/success',
      cancel_url: YOUR_DOMAIN + '/cancel',
    })
    result = session
    if result
      @current_order.placed!
      current_user.tokens ||= 0
      current_user.tokens += @current_order.total_coin_value
      current_user.save!
      flash[:notice] = "Nice! You just bought #{@current_order.total_coin_value} tokens!"
      user_session['order_id'] = nil
      redirect_to session.url, status: :see_other, allow_other_host: true
    else
      error_messages = result.errors.map { |error| "Error: #{error.code}: #{error.message}" }
      flash[:error] = error_messages
      redirect_to new_checkout_path
      # redirect_to @checkout_session.url, allow_other_host: true, status: :see_other
    end
  end

  def success
    @current_order = current_order
    @current_order.placed!
    current_user.tokens ||= 0
    current_user.tokens += @current_order.total_coin_value
    current_user.save!
    flash[:notice] = "Nice! You just bought #{@current_order.total_coin_value} tokens!"
    user_session['order_id'] = nil
    redirect_to root_path
  end

  def cancel
    flash[:error] = "Sorry, something went wrong. Please try again."
    redirect_to root_path
  end
end
