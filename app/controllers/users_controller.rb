class UsersController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_back_or_to root_url unless current_user.admin?
    @users = User.all.order(created_at: :desc).page params[:page]
  end

  def show
    # redirect_back_or_to root_url unless current_user.admin? || current_user.id == params[:id].to_i
    @user = User.find(params[:id])
  end

  def remove_user_doc
    @user_doc = UserDoc.find(params[:id])
    @user_doc.destroy
    redirect_back_or_to root_url
  end

  def edit
    @user = User.find(params[:id])
  end

  def update
    @user = User.find(params[:id])
    if @user.update(user_params)
      redirect_to user_path(@user), notice: "Successfully updated."
    else
      render 'edit', alert: "There was an error updating the user.\nErrors: #{user.errors.full_messages.join(', ')}"
    end
  end

  private 

  def user_params
    params.require(:user).permit(:name)
  end
end
