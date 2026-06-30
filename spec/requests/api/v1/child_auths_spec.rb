require "rails_helper"

# Private passcode sign-in for communicators, with the fallback-mode gate
# from issue #255. A fallback communicator (over the Free slot limit after a
# downgrade) cannot sign in privately and is redirected to its public page.
RSpec.describe "API::V1::ChildAuths", type: :request do
  let(:login_path) { "/api/v1/child_accounts/login" }

  def login(account)
    post login_path, params: { username: account.username, password: account.passcode }
    JSON.parse(response.body)
  end

  describe "POST /child_accounts/login" do
    it "signs in a normal communicator with valid credentials" do
      owner = FactoryBot.create(:user)
      owner.update!(plan_type: "pro")
      account = FactoryBot.create(:child_account, user: owner, status: ChildAccount::ACTIVE,
                                                  passcode: "secret123")

      body = login(account)

      expect(response).to have_http_status(:ok)
      expect(body["token"]).to be_present
    end

    it "blocks a fallback communicator and redirects to the public page" do
      owner = FactoryBot.create(:user)
      owner.update!(plan_type: "pro")
      account = FactoryBot.create(:child_account, user: owner, status: ChildAccount::ACTIVE,
                                                  passcode: "secret123")
      account.create_profile!
      account.enter_fallback!
      account.reload # pick up the profile association created above

      body = login(account)

      expect(response).to have_http_status(:forbidden)
      expect(body["error"]).to eq("communicator_in_fallback")
      expect(account.public_url).to be_present
      expect(body["redirect_url"]).to eq(account.public_url)
      expect(body["token"]).to be_nil
    end

    it "lets a system admin owner bypass the fallback gate (support access)" do
      admin = FactoryBot.create(:admin_user)
      account = FactoryBot.create(:child_account, user: admin, status: ChildAccount::ACTIVE,
                                                  passcode: "secret123")
      account.enter_fallback!

      body = login(account)

      expect(response).to have_http_status(:ok)
      expect(body["token"]).to be_present
    end

    it "returns unauthorized for invalid credentials" do
      post login_path, params: { username: "nope", password: "wrong" }
      expect(response).to have_http_status(:unauthorized)
    end

    # Regression: the admin bypass path (reached when can_sign_in? is false but
    # the owner is an admin — e.g. a passcode-bearing sandbox, whose sandbox
    # guard short-circuits can_sign_in? before the admin check) must serialize
    # the communicator through api_view, like every other success path, rather
    # than dumping the raw ActiveRecord model (wrong shape for the frontend +
    # leaks internal columns).
    it "renders the api_view shape (not the raw model) on the admin bypass path" do
      admin = FactoryBot.create(:admin_user)
      account = FactoryBot.create(:child_account, user: admin, status: ChildAccount::SANDBOX,
                                                  passcode: "secret123")

      body = login(account)

      expect(response).to have_http_status(:ok)
      expect(body["token"]).to be_present
      # parent_name is an api_view-only key (computed, not a column); updated_at
      # is a raw column api_view never emits.
      expect(body["account"]).to include("parent_name")
      expect(body["account"]).not_to have_key("updated_at")
    end
  end
end
