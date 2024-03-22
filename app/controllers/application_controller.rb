# class UserContext
#   attr_reader :user, :team

#   def initialize(user, team)
#     @user = user
#     @team = user.cur
#   end

#   def id
#     user&.id
#   end

#   def admin?
#     user&.admin?
#   end

#   def team_boards
#     return [] if user.nil? || team.nil?
#     user.team_boards.where(team_id: team.id)
#   end
# end
class ApplicationController < ActionController::Base
  include Pundit::Authorization
  # protect_from_forgery with: :exception
  # protect_from_forgery with: :null_session
  skip_before_action :verify_authenticity_token

  before_action :configure_permitted_parameters, if: :devise_controller?
  helper_method :current_order
  before_action :set_categories, :set_teams, :set_current_team

  before_action :authenticate_user!, only: [:current_order]

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  def current_team
    return nil if current_user.nil?
    current_user.current_team
    # if current_user.current_team.nil?
    #   team = current_user.teams.first
    #   current_user.update(current_team: team)
    # else
    #   team = current_user.current_team
    # end
    # team
  end

  def set_current_team
    @current_team ||= current_team
  end    

  def current_order
    return nil if current_user.nil?
    if user_session['order_id'].nil?
      order = current_user.orders.in_progress.last || current_user.orders.create!
    else
      begin
        order = current_user.orders.in_progress.find(user_session['order_id'])
      rescue ActiveRecord::RecordNotFound => e
        order = current_user.orders.create!
      rescue => e
        puts "\n\n****Error: #{e.inspect}\n\n"
      end
    end
    user_session['order_id'] = order.id unless order.nil?
    order
  end

  def token
    @open_symbol_id_token = OpenSymbol.get_token
    @open_symbol_id_token
  end

  protected
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:name])
  end

  private
  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_to(request.referrer || root_path)
  end

  def set_categories
    @categories = ProductCategory.all
  end

  def set_teams
    @teams = policy_scope(Team)
  end
end
