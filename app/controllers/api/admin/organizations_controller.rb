class API::Admin::OrganizationsController < API::Admin::ApplicationController
  def index
    @organizations = Organization.all.order(created_at: :desc)
    render json: @organizations.map { |org| org.api_view(current_admin) }
  end

  def show
    @organization = Organization.find(params[:id])
    render json: @organization.api_view(current_admin)
  end

  def create
    @organization = Organization.new(organization_params)
    if @organization.save
      render json: @organization.api_view(current_admin), status: :created
    else
      render json: @organization.errors, status: :unprocessable_entity
    end
  end

  def update
    @organization = Organization.find(params[:id])
    if @organization.update(organization_params)
      render json: @organization.api_view(current_admin)
    else
      render json: @organization.errors, status: :unprocessable_entity
    end
  end

  def assign_user
    @organization = Organization.find(params[:id])
    inviting_user_id = @organization.admin_user_id
    user_email = params[:user_email]
    @user = User.invite!(email: user_email, skip_invitation: true)
    if @user
      if inviting_user_id
        @user.invited_by_id = inviting_user_id
        @user.invited_by_type = "User"
        @user.send_welcome_to_organization_email(@organization)
      end
      stripe_customer_id = User.create_stripe_customer(user_email)
      @user.stripe_customer_id = stripe_customer_id
      @user.organization_id = @organization.id
      @user.save
    else
      render json: { error: "Failed to invite user" }, status: :unprocessable_entity
      return
    end
    render json: @user.api_view

    # if @organization.users << @user
    #   render json: @organization.api_view(current_admin)
    # else
    #   render json: { error: "Failed to assign user" }, status: :unprocessable_entity
    # end
  end

  def remove_user
    @organization = Organization.find(params[:id])
    @user = User.find(params[:user_id])
    if @organization.users.delete(@user)
      render json: @organization.api_view(current_admin)
    else
      render json: { error: "Failed to remove user" }, status: :unprocessable_entity
    end
  end

  def destroy
    @organization = Organization.find(params[:id])
    if @organization.destroy
      render json: { message: "Organization deleted successfully" }, status: :ok
    else
      render json: { error: "Failed to delete organization" }, status: :unprocessable_entity
    end
  end

  private

  def organization_params
    params.require(:organization).permit(:name, :admin_user_id, :settings, :stripe_customer_id, :plan_type, :slug)
  end
end
