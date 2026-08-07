require "rails_helper"

RSpec.describe "Admin::Placeholders (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    # Creating the owner for a placeholder runs User.create_from_email, which
    # provisions a Stripe customer. Without this the suite makes a real API
    # call and dies on Stripe::AuthenticationError (CI has no key).
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_#{SecureRandom.hex(4)}")
  end

  describe "authorization" do
    it "redirects a non-admin" do
      sign_in create(:user)

      get admin_dashboard_placeholders_path

      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_placeholders_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/placeholders" do
    it "lists placeholder profiles with claim URL and QR code" do
      sign_in admin
      profile = Profile.generate_with_username("printcard1")

      get admin_dashboard_placeholders_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("printcard1")
      expect(response.body).to include(profile.claim_url)
      expect(response.body).to include("data:image/png;base64,")
    end

    it "does not list non-placeholder profiles" do
      sign_in admin
      create(:profile, username: "regular_profile", placeholder: false)

      get admin_dashboard_placeholders_path

      expect(response.body).not_to include("regular_profile")
    end
  end

  describe "POST /admin/placeholders" do
    it "creates and claims a profile for an existing user (generate_with_username's actual behavior)" do
      sign_in admin
      owner = create(:user, email: "owner@example.com")

      expect {
        post admin_dashboard_placeholders_path, params: { username: "handout1", user_email: owner.email }
      }.to change(Profile, :count).by(1)

      profile = Profile.find_by(username: "handout1")
      expect(profile).not_to be_placeholder
      expect(profile.claimed_at).to be_present
      expect(profile.profileable).to be_a(ChildAccount)
      expect(profile.profileable.owner_id).to eq(owner.id)
      expect(response).to redirect_to(admin_dashboard_placeholders_path)
    end

    it "invites a brand-new email as a user before creating the placeholder" do
      sign_in admin

      expect {
        post admin_dashboard_placeholders_path, params: { username: "handout2", user_email: "brandnew@example.com" }
      }.to change(User, :count).by(1).and change(Profile, :count).by(1)
    end

    it "rejects a username that's already taken" do
      sign_in admin
      owner = create(:user)
      Profile.generate_with_username("taken", owner)

      expect {
        post admin_dashboard_placeholders_path, params: { username: "taken", user_email: "someoneelse@example.com" }
      }.not_to change(Profile, :count)

      expect(response).to redirect_to(admin_dashboard_placeholders_path)
      follow_redirect!
      expect(response.body).to include("has been taken")
    end

    it "requires an email" do
      sign_in admin

      expect {
        post admin_dashboard_placeholders_path, params: { username: "handout3" }
      }.not_to change(Profile, :count)

      expect(response).to redirect_to(admin_dashboard_placeholders_path)
    end
  end
end
