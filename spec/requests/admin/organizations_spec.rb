require "rails_helper"

RSpec.describe "Admin::Organizations (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      organization = create(:organization)

      get admin_dashboard_organizations_path
      expect(response).to redirect_to(root_path)

      get admin_dashboard_organization_path(organization)
      expect(response).to redirect_to(root_path)

      get new_admin_dashboard_organization_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_organizations_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/organizations" do
    it "lists organizations" do
      sign_in admin
      organization = create(:organization, name: "Sunny Elementary")

      get admin_dashboard_organizations_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sunny Elementary")
    end
  end

  describe "GET /admin/organizations/:id" do
    it "shows organization detail and members" do
      sign_in admin
      organization = create(:organization, name: "Sunny Elementary")
      member = create(:user, organization: organization, email: "member@example.com")

      get admin_dashboard_organization_path(organization)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sunny Elementary")
      expect(response.body).to include(member.email)
    end

    it "filters members by member_search" do
      sign_in admin
      organization = create(:organization)
      create(:user, organization: organization, email: "alice@example.com")
      bob = create(:user, organization: organization, email: "bob@example.com")

      get admin_dashboard_organization_path(organization, member_search: "bob")

      expect(response.body).to include(bob.email)
      expect(response.body).not_to include("alice@example.com")
    end
  end

  describe "POST /admin/organizations" do
    it "creates an organization" do
      sign_in admin
      org_admin = create(:user)

      expect {
        post admin_dashboard_organizations_path, params: { organization: { name: "New Org", slug: "new-org", admin_user_id: org_admin.id } }
      }.to change(Organization, :count).by(1)

      expect(response).to redirect_to(admin_dashboard_organization_path(Organization.last))
    end

    it "re-renders the form on validation failure" do
      sign_in admin

      expect {
        post admin_dashboard_organizations_path, params: { organization: { name: "" } }
      }.not_to change(Organization, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PUT /admin/organizations/:id" do
    it "updates an organization" do
      sign_in admin
      organization = create(:organization, name: "Old Name")

      put admin_dashboard_organization_path(organization), params: { organization: { name: "New Name" } }

      expect(response).to redirect_to(admin_dashboard_organization_path(organization))
      expect(organization.reload.name).to eq("New Name")
    end
  end

  describe "POST /admin/organizations/:id/assign_user" do
    it "adds an existing user to the organization" do
      sign_in admin
      organization = create(:organization)
      user = create(:user, email: "existing@example.com")

      post assign_user_admin_dashboard_organization_path(organization), params: { user_email: user.email }

      expect(response).to redirect_to(admin_dashboard_organization_path(organization))
      expect(user.reload.organization_id).to eq(organization.id)
    end

    it "invites a brand-new email and adds them to the organization" do
      sign_in admin
      organization = create(:organization)

      expect {
        post assign_user_admin_dashboard_organization_path(organization), params: { user_email: "brandnew@example.com" }
      }.to change(User, :count).by(1)

      new_user = User.find_by(email: "brandnew@example.com")
      expect(new_user.organization_id).to eq(organization.id)
    end
  end
end
