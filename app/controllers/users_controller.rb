class UsersController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_back_or_to root_url unless current_user.admin?
    @users = User.all.order(created_at: :desc).page params[:page]
  end

  def show
    redirect_back_or_to root_url unless current_user.admin? || current_user.id == params[:id].to_i
    @user = User.find(params[:id])
  end
end
