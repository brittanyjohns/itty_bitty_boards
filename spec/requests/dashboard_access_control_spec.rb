require "rails_helper"

# GET /dashboard renders an HTML page that assumes a signed-in user: the view
# reads @user.teams and the action runs policy_scope(Board). Without a gate an
# anonymous request reached BoardPolicy::Scope#resolve with a nil user and 500'd
# on `undefined method 'admin?' for nil`.
RSpec.describe "MainController#dashboard access control", type: :request do
  include Devise::Test::IntegrationHelpers

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  it "redirects an anonymous visitor to sign in instead of raising" do
    get "/dashboard"

    expect(response).to have_http_status(:redirect)
    expect(response.location).to include("/users/sign_in")
  end

  it "renders for a signed-in user" do
    sign_in create(:user)

    get "/dashboard"

    expect(response).to have_http_status(:ok)
  end
end
