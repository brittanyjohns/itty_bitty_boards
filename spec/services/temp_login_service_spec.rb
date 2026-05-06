require "rails_helper"

RSpec.describe TempLoginService, type: :service do
  describe ".issue_for!" do
    let(:user) { FactoryBot.create(:user) }

    it "returns a non-blank token string" do
      token = described_class.issue_for!(user)
      expect(token).to be_a(String)
      expect(token).not_to be_blank
    end

    it "saves the token on the user record" do
      token = described_class.issue_for!(user)
      expect(user.reload.temp_login_token).to eq(token)
    end

    it "sets temp_login_expires_at to roughly EXPIRY hours from now" do
      described_class.issue_for!(user)
      expiry_hours = User::TEMP_LOGIN_TOKEN_EXPIRY_HOURS
      expect(user.reload.temp_login_expires_at).to be_within(5.seconds).of(expiry_hours.hours.from_now)
    end

    it "forces a password reset on the user" do
      described_class.issue_for!(user)
      expect(user.reload.force_password_reset).to be true
    end

    it "generates a unique token on each call" do
      token_a = described_class.issue_for!(user)
      token_b = described_class.issue_for!(user)
      expect(token_a).not_to eq(token_b)
    end
  end
end
