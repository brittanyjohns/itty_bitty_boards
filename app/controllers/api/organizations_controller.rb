class API::OrganizationsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public]

  def show
    @organization = Organization.find(params[:id])
    render json: @organization
  end

  def update
    @organization = Organization.find(params[:id])
    if @organization.update(organization_params)
      render json: @organization.api_view(current_user)
    else
      render json: @organization.errors, status: :unprocessable_entity
    end
  end

  private

  def organization_params
    params.require(:organization).permit(:name, :admin_user_id, :settings, :stripe_customer_id, :plan_type)
  end
end
