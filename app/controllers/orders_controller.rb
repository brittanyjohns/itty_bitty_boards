class OrdersController < ApplicationController
  def index
    @orders = current_user.orders.all.order(created_at: :desc)
  end

  def show
    @order = Order.find(params[:id])
  end
end
