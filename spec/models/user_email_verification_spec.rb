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

  describe "welcome tokens" do
    it "does NOT grant tokens on account creation" do
      user = FactoryBot.create(:user)
      expect(user.tokens).to eq(0)
    end

    it "grants tokens when the address is verified" do
      user = FactoryBot.create(:user, confirmed_at: nil)

      expect(user.mark_email_verified!).to be(true)

      expect(user.reload.tokens).to eq(10)
      expect(user.email_verified?).to be(true)
    end

    # Deliberately NOT cleared. Email security scanners (Outlook Safe Links,
    # Mimecast) prefetch links, and users double-click. Keeping the token lets
    # a replay still resolve to this user so the endpoint can answer "already
    # confirmed" instead of a scary "invalid link". It grants nothing once
    # confirmed_at is set, and expires on its own after 7 days.
    it "retains the verification token so a replayed link can still be resolved" do
      user = FactoryBot.create(:user, confirmed_at: nil,
                                      email_verification_token: "abc123",
                                      email_verification_sent_at: Time.current)

      user.mark_email_verified!

      expect(user.reload.email_verification_token).to eq("abc123")
    end

    it "is idempotent — a second call never double-grants" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      user.mark_email_verified!

      expect(user.mark_email_verified!).to be(false)
      expect(user.reload.tokens).to eq(10)
    end

    it "leaves an already-verified user's balance untouched" do
      user = FactoryBot.create(:user, confirmed_at: 1.day.ago)
      user.update!(tokens: 3)

      expect(user.mark_email_verified!).to be(false)
      expect(user.reload.tokens).to eq(3)
    end
  end
end
