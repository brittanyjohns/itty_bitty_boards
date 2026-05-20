require "rails_helper"

RSpec.describe "API::Audits word click", type: :request do
  let!(:user) { create(:user) }
  let!(:account) { create(:child_account, user: user) }

  def word_click_params(overrides = {})
    { word: "hello", layout: {}, screenSize: "lg" }.merge(overrides)
  end

  describe "POST /api/word_click" do
    it "requires authentication" do
      post "/api/word_click", params: word_click_params, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a WordEvent for an authenticated user" do
      expect {
        post "/api/word_click", params: word_click_params, headers: auth_headers(user), as: :json
      }.to change(WordEvent, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it "creates a WordEvent for a communicator account" do
      expect {
        post "/api/word_click", params: word_click_params, headers: auth_headers(account), as: :json
      }.to change(WordEvent, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it "does not create a WordEvent when the user has audit logging disabled" do
      user.update!(settings: (user.settings || {}).merge("disable_audit_logging" => true))

      expect {
        post "/api/word_click", params: word_click_params, headers: auth_headers(user), as: :json
      }.not_to change(WordEvent, :count)
      expect(response).to have_http_status(:ok)
    end

    it "does not create a WordEvent when the communicator account has audit logging disabled" do
      account.update!(settings: (account.settings || {}).merge("disable_audit_logging" => true))

      expect {
        post "/api/word_click", params: word_click_params, headers: auth_headers(account), as: :json
      }.not_to change(WordEvent, :count)
      expect(response).to have_http_status(:ok)
    end
  end
end
