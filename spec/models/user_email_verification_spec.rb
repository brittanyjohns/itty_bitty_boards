require "rails_helper"

RSpec.describe User, "email verification state" do
  describe "#email_verified?" do
    it "is false for an account with no email_verified_at" do
      user = FactoryBot.create(:user, email_verified_at: nil)
      expect(user.email_verified?).to be(false)
    end

    it "is true once email_verified_at is set" do
      user = FactoryBot.create(:user, email_verified_at: Time.current)
      expect(user.email_verified?).to be(true)
    end
  end

  describe "#api_view" do
    it "exposes email_verified so the frontend can render the banner" do
      user = FactoryBot.create(:user, email_verified_at: nil)
      expect(user.api_view[:email_verified]).to be(false)

      user.update!(email_verified_at: Time.current)
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
    # email_verified_at is set, and expires on its own after 7 days.
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
      user = FactoryBot.create(:user, email_verified_at: 1.day.ago)
      user.update!(tokens: 3)

      expect(user.mark_email_verified!).to be(false)
      expect(user.reload.tokens).to eq(3)
    end
  end

  describe "AI credit grant" do
    it "does NOT grant plan credits on account creation" do
      user = FactoryBot.create(:user)
      expect(user.credit_transactions.where(kind: "plan_grant")).to be_empty
      expect(CreditService.balance(user)[:total]).to eq(0)
    end

    it "grants the free-tier credit allowance on verification" do
      user = FactoryBot.create(:user, confirmed_at: nil)

      user.mark_email_verified!

      expect(CreditService.balance(user.reload)[:total]).to eq(
        CreditService.monthly_credits_for("free")
      )
    end

    it "grants both currencies in one call" do
      user = FactoryBot.create(:user, confirmed_at: nil)

      user.mark_email_verified!

      expect(user.reload.tokens).to eq(10)
      expect(CreditService.balance(user)[:total]).to eq(25)
    end

    it "does not double-grant credits when called twice" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      user.mark_email_verified!
      user.reload

      user.mark_email_verified!

      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
      expect(CreditService.balance(user.reload)[:total]).to eq(25)
    end
  end

  describe "verification tokens" do
    it "generates a token and stamps the send time" do
      user = FactoryBot.create(:user, confirmed_at: nil)

      token = user.generate_email_verification_token!

      expect(token).to be_present
      expect(user.reload.email_verification_token).to eq(token)
      expect(user.email_verification_sent_at).to be_within(5.seconds).of(Time.current)
    end

    it "treats a fresh token as valid and a 8-day-old one as expired" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      user.generate_email_verification_token!
      expect(user.email_verification_token_valid?).to be(true)

      user.update!(email_verification_sent_at: 8.days.ago)
      expect(user.email_verification_token_valid?).to be(false)
    end

    it "blocks a resend inside the cooldown and allows one after" do
      user = FactoryBot.create(:user, confirmed_at: nil)
      user.generate_email_verification_token!
      expect(user.can_resend_email_verification?).to be(false)

      user.update!(email_verification_sent_at: 6.minutes.ago)
      expect(user.can_resend_email_verification?).to be(true)
    end

    it "allows a resend when nothing has ever been sent" do
      user = FactoryBot.create(:user, confirmed_at: nil, email_verification_sent_at: nil)
      expect(user.can_resend_email_verification?).to be(true)
    end
  end

  describe "email_verified_at ownership" do
    # Regression guard. devise_invitable stamps confirmed_at on accept_invitation!
    # for any model with that column, so confirmed_at can never be our source of
    # truth — see the task-7r brief.
    it "is not verified merely because confirmed_at is set" do
      user = FactoryBot.create(:user, confirmed_at: Time.current, email_verified_at: nil)
      expect(user.email_verified?).to be(false)
    end

    it "reads email_verified_at, not confirmed_at" do
      user = FactoryBot.create(:user, email_verified_at: nil)
      user.mark_email_verified!
      expect(user.reload.email_verified_at).to be_present
    end
  end
end
