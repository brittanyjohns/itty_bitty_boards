class OrderItemsController < ApplicationController
  def create
    product_id = params[:order_item][:product_id]
    number_to_add = params[:order_item][:quantity].to_i

    puts "***\nCREATE\n***\n#{product_id}\n#{number_to_add}\n***\n"

    if user_session['order_id']
      @order_item = OrderItem.where("product_id = ? AND order_id = ?", product_id, user_session['order_id']).first
    end
    if @order_item
      @order_item.quantity += number_to_add
    else
      @order_item = current_order.order_items.new(order_item_params)
    end

    if @order_item.save
      flash[:notice] = "You've added #{(number_to_add * @order_item.coin_value).to_i} tokens to your cart!"
      redirect_to product_url(@order_item.product)
    elsif @order_item.errors
      error_messages = @order_item.errors.map { |error| "Error: #{error.code}: #{error.message}" }
      flash[:error] = error_messages
      puts "ERROR: #{@order_item.errors.inspect}"
      redirect_to product_url(@order_item.product)
    end
  end

  def show
    @order = current_order
    @order_item = @order.order_items.find(params[:id])
  end

  def update
    puts "***\nUPDATE\n***"
    @order = current_order
    @order_item = @order.order_items.find(params[:id])
    @order_item.update(order_item_params)
    @order_items = @order.order_items
    redirect_to carts_show_path
  end

  def destroy
    puts "***\nDESTORY\n***"
    @order = current_order
    @order_item = @order.order_items.find(params[:id])
    @order_item.destroy
    @order.save! # Updating totals - might be better to use a callback here ???
    @order_items = @order.order_items
    redirect_to carts_show_path
  end

  private

  def order_item_params
    params.require(:order_item).permit(:quantity, :product_id)
  end
end
