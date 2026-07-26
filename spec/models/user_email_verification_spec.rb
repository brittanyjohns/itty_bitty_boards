require "rails_helper"

RSpec.describe User, "email verification state" do
  describe "#email_verified?" do
    it "is false for an account with no confirmed_at" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      expect(user.email_verified?).to be(false)
    end

    it "is true once confirmed_at is set" do
      user = FactoryBot.create(:user, confirmed_at: Time.current)
      expect(user.email_verified?).to be(true)
    end
  end

  describe "#api_view" do
    it "exposes email_verified so the frontend can render the banner" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      expect(user.api_view[:email_verified]).to be(false)

      user.update!(confirmed_at: Time.current)
      expect(user.api_view[:email_verified]).to be(true)
    end
  end
end
