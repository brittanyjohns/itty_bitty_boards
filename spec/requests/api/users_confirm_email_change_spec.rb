require "rails_helper"

RSpec.describe "GET /api/confirm_email_change", type: :request do
  let(:user) do
    FactoryBot.create(:user, email: "old@example.com").tap do |u|
      u.update!(unconfirmed_email: "new@example.com",
                confirmation_token: "changetoken123",
                confirmation_sent_at: Time.current)
    end
  end

  # confirm_email_change requires auth: the mailer link points at the
  # frontend route (/confirm-email?confirmation_token=...), which is loaded
  # by the already-signed-in SPA and calls this API with the user's existing
  # bearer token attached — unlike verify_email, which is hit unauthenticated
  # straight from an inbox before any session exists.
  it "promotes the pending address with a fresh token" do
    get "/api/confirm_email_change", params: { confirmation_token: user.confirmation_token },
                                      headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(user.reload.email).to eq("new@example.com")
    expect(user.unconfirmed_email).to be_nil
  end

  it "rejects a token older than the validity window and leaves the address alone" do
    user.update!(confirmation_sent_at: 8.days.ago)

    get "/api/confirm_email_change", params: { confirmation_token: user.confirmation_token },
                                      headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.email).to eq("old@example.com")
    expect(user.unconfirmed_email).to eq("new@example.com")
  end

  # Part 2: confirming an email change is proof of inbox access on the new
  # address, so it should route through mark_email_verified! the same as the
  # dedicated verification link — an unverified user who changes their email
  # should not be stuck unverified forever with no welcome tokens/credits.
  describe "verification side effect" do
    let(:unverified_user) do
      FactoryBot.create(:user, email: "old@example.com", email_verified_at: nil).tap do |u|
        u.update!(unconfirmed_email: "new@example.com",
                  confirmation_token: "changetoken456",
                  confirmation_sent_at: Time.current)
      end
    end

    it "verifies an unverified user, whose signup grants are already in place" do
      get "/api/confirm_email_change", params: { confirmation_token: unverified_user.confirmation_token },
                                        headers: auth_headers(unverified_user)

      expect(response).to have_http_status(:ok)
      unverified_user.reload
      expect(unverified_user.email).to eq("new@example.com")
      expect(unverified_user.email_verified?).to be(true)
      expect(unverified_user.tokens).to eq(User::WELCOME_TOKENS)
      expect(CreditService.balance(unverified_user)[:total]).to eq(
        CreditService.monthly_credits_for("free")
      )
    end

    it "leaves an already-verified user verified and does not double-grant" do
      verified_user = FactoryBot.create(:user, email: "old2@example.com", email_verified_at: 1.day.ago).tap do |u|
        u.update!(unconfirmed_email: "new2@example.com",
                  confirmation_token: "changetoken789",
                  confirmation_sent_at: Time.current)
      end
      verified_user.update!(tokens: 3)
      previous_balance = CreditService.balance(verified_user)[:total]

      get "/api/confirm_email_change", params: { confirmation_token: verified_user.confirmation_token },
                                        headers: auth_headers(verified_user)

      expect(response).to have_http_status(:ok)
      verified_user.reload
      expect(verified_user.email).to eq("new2@example.com")
      expect(verified_user.email_verified?).to be(true)
      expect(verified_user.tokens).to eq(3)
      expect(CreditService.balance(verified_user)[:total]).to eq(previous_balance)
    end
  end
end
