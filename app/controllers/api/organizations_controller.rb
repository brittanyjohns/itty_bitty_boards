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
      render json: @organization.errors, status: :unprocessable_content
    end
  end

  private

  def organization_params
    # :admin_user_id (ownership), :plan_type (billing tier) and :stripe_customer_id
    # are intentionally NOT permitted on this (non-admin) controller — they must
    # not be client-settable via mass-assignment. Org billing/ownership is curated
    # only through the admin-gated API::Admin::OrganizationsController (#27).
    params.require(:organization).permit(:name, :settings)
  end
end
