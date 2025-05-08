class API::CheckoutsController < API::ApplicationController
  FRONT_END_URL = ENV["FRONT_END_URL"]
  PRO_PLAN_PRICE_ID = ENV["PRO_PLAN_PRICE_ID"]

  def create
    @amount = params[:amount] || 1

    quantity = @amount.to_i

    @user = current_user

    result = nil

    result = StripeClient.add_commuicator_account(@user.id, quantity)

    if result
      render json: { success: true }, status: :ok
    else
      render json: { error: "Failed to add extra communicators" }, status: :unprocessable_entity
    end
  end

  def success
    @current_order = current_order
    @current_order.placed!
    current_user.tokens ||= 0
    current_user.tokens += @current_order.total_coin_value
    current_user.save!
    flash[:notice] = "Nice! You just bought #{@current_order.total_coin_value} tokens!"
    user_session["order_id"] = nil
    redirect_to root_path
  end

  def cancel
    flash[:error] = "Sorry, something went wrong. Please try again."
    redirect_to root_path
  end
end
