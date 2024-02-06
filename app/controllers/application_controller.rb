class ApplicationController < ActionController::Base
    # protect_from_forgery with: :exception
    # protect_from_forgery with: :null_session
    skip_before_action :verify_authenticity_token

    before_action :configure_permitted_parameters, if: :devise_controller?
    helper_method :current_order
    before_action :set_categories

    before_action :authenticate_user!, only: [:current_order]

  
    def current_order
      return nil if current_user.nil?
      if user_session['order_id'].nil?
        order = current_user.orders.in_progress.last || current_user.orders.create!
        puts "Creating new order for user #{current_user.id} - #{order.id}"
      else
        begin
          order = current_user.orders.in_progress.find(user_session['order_id'])
          puts "Found order for user #{current_user.id} - #{order.id}"
        rescue ActiveRecord::RecordNotFound => e
          order = current_user.orders.create!
          puts "Creating new order for user #{current_user.id} - #{order.id}"
        rescue => e
          puts "\n\n****Error: #{e.inspect}\n\n"
        end
      end
      user_session['order_id'] = order.id unless order.nil?
      order
    end

    def token
      @open_symbol_id_token = OpenSymbol.get_token
      puts "Token: #{@open_symbol_id_token}"
      @open_symbol_id_token
    end

    # def generate_symbol(query)
    #   @open_symbol_id_token = open_symbol_id_token
    #   token_to_send = CGI.escape(@open_symbol_id_token)
    #   query_to_send = CGI.escape(query)
    #   uri = URI("https://www.opensymbols.org/api/v2/symbols?access_token=#{token_to_send}&q=#{query_to_send}")
    #   response = Net::HTTP.get(uri)

    #   response
    # end

    protected

    def configure_permitted_parameters
      devise_parameter_sanitizer.permit(:sign_up, keys: [:name])
    end
  
    private
  
    def set_categories
      @categories = ProductCategory.all
    end
end
