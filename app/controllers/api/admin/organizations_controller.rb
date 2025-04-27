class API::Admin::OrganizationsController < API::Admin::ApplicationController
  def index
    @organizations = Organization.all.order(created_at: :desc)
    render json: @organizations.map { |org| org.api_view(current_admin) }
  end

  def show
    @organization = Organization.find(params[:id])
    render json: @organization
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
    @user = User.find(params[:user_id])
    if @organization.users << @user
      render json: @organization.api_view(current_admin)
    else
      render json: { error: "Failed to assign user" }, status: :unprocessable_entity
    end
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
    params.require(:organization).permit(:name, :admin_user_id, :settings, :stripe_customer_id, :plan_type)
  end
end
