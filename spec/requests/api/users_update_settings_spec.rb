require "rails_helper"

# Covers the hardened API::UsersController#update_settings: it now only
# persists whitelisted keys (no more blindly writing every request param into
# settings, which used to leak controller/action/id/format and let any caller
# set arbitrary keys), and requires the caller to be the owner or an admin.
RSpec.describe "PUT /api/users/:id/update_settings", type: :request do
  let(:user) { FactoryBot.create(:user) }

  def update(target, body, as_user: target)
    put "/api/users/#{target.id}/update_settings",
        params: body, headers: auth_headers(as_user), as: :json
  end

  describe "whitelisting" do
    it "persists whitelisted preference keys" do
      update(user, { wait_to_speak: true, disable_audit_logging: true })

      expect(response).to have_http_status(:ok)
      settings = user.reload.settings
      expect(settings["wait_to_speak"]).to be(true)
      expect(settings["disable_audit_logging"]).to be(true)
    end

    it "ignores Rails-injected and arbitrary non-whitelisted keys" do
      update(user, { wait_to_speak: true, board_limit: 999, ai_monthly_limit: 42, hacked: "x" })

      settings = user.reload.settings
      expect(settings["wait_to_speak"]).to be(true)
      # Plan/limit keys are owned by the webhook/admin paths, never this endpoint.
      expect(settings["board_limit"]).to eq(User::FREE_PLAN_LIMITS["board_limit"])
      expect(settings).not_to have_key("ai_monthly_limit")
      expect(settings).not_to have_key("hacked")
      # Rails request metadata must never land in settings.
      %w[controller action id format].each do |junk|
        expect(settings).not_to have_key(junk)
      end
    end

    it "deep-merges the voice block, preserving unspecified voice fields" do
      user.update!(settings: user.settings.merge(
        "voice" => { "name" => "polly:kevin", "language" => "en-US", "speed" => 1.0 }
      ))

      update(user, { voice: { language: "es-US" } })

      voice = user.reload.settings["voice"]
      expect(voice["language"]).to eq("es-US")
      expect(voice["name"]).to eq("polly:kevin") # preserved
      expect(voice["speed"]).to eq(1.0)          # preserved
    end
  end

  describe "authorization" do
    it "rejects a different non-admin user with 401 and writes nothing" do
      other = FactoryBot.create(:user)

      update(user, { wait_to_speak: true }, as_user: other)

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.settings["wait_to_speak"]).not_to be(true)
    end

    it "lets an admin update another user's settings" do
      admin = FactoryBot.create(:admin_user)

      update(user, { wait_to_speak: true }, as_user: admin)

      expect(response).to have_http_status(:ok)
      expect(user.reload.settings["wait_to_speak"]).to be(true)
    end
  end
end
