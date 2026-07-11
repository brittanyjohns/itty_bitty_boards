class API::OrganizationsController < API::ApplicationController
  def show
    @organization = Organization.find(params[:id])
    render json: @organization
  end

  def update
    @organization = Organization.find(params[:id])
    # Broken-access-control gate (#469): only the org's admin_user (owner) or a
    # site admin may mutate an organization. The endpoint is currently unrouted,
    # but the gate must exist before it's ever wired up.
    unless current_user&.admin? || @organization.admin_user_id == current_user&.id
      render json: { error: "Unauthorized" }, status: :forbidden
      return
    end
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
