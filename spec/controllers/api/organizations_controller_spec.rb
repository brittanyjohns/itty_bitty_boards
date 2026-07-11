require "rails_helper"

# Issue #469 (broken access control): API::OrganizationsController#update had no
# ownership/admin gate. The endpoint is currently unrouted, so a temporary route
# is drawn here to exercise the action directly and prove the gate rejects a
# non-owner while owner/admin can still update.
RSpec.describe API::OrganizationsController, type: :controller do
  # The endpoint is unrouted in the real app; use an ISOLATED RouteSet so the
  # temporary route doesn't clobber Rails.application.routes for the rest of the
  # suite.
  before do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { patch "api/organizations/:id" => "api/organizations#update" }
  end

  let!(:owner)      { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }
  let!(:organization) { create(:organization, admin_user_id: owner.id, name: "Original") }

  def authenticate(user)
    request.headers["Authorization"] = "Bearer #{user.authentication_token}"
  end

  it "rejects a non-owner with 403 and does not mutate the organization" do
    authenticate(other_user)
    patch :update, params: { id: organization.id, organization: { name: "Hacked" } }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(organization.reload.name).to eq("Original")
  end

  it "rejects an unauthenticated request with 401" do
    patch :update, params: { id: organization.id, organization: { name: "Hacked" } }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(organization.reload.name).to eq("Original")
  end

  it "lets the owner update the organization" do
    authenticate(owner)
    patch :update, params: { id: organization.id, organization: { name: "Renamed" } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(organization.reload.name).to eq("Renamed")
  end

  it "lets a site admin update any organization" do
    authenticate(admin)
    patch :update, params: { id: organization.id, organization: { name: "Admin Renamed" } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(organization.reload.name).to eq("Admin Renamed")
  end
end
