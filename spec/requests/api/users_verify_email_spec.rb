require "rails_helper"

RSpec.describe "GET /api/verify_email", type: :request do
  let(:user) { FactoryBot.create(:user, confirmed_at: nil) }

  def verify(token)
    get "/api/verify_email", params: { token: token }
  end

  it "verifies the account" do
    token = user.generate_email_verification_token!

    verify(token)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["email_verified"]).to be(true)
    expect(user.reload.email_verified?).to be(true)
    expect(user.tokens).to eq(User::WELCOME_TOKENS)
  end

  it "works without authentication — the link is clicked from an inbox" do
    token = user.generate_email_verification_token!
    verify(token) # no auth_headers
    expect(response).to have_http_status(:ok)
  end

  it "rejects an unknown token" do
    verify("not-a-real-token")

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to be_present
  end

  it "rejects an expired token without verifying the account" do
    token = user.generate_email_verification_token!
    user.update!(email_verification_sent_at: 8.days.ago)

    verify(token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.email_verified?).to be(false)
  end

  # Double-clicks and email security scanners (Outlook Safe Links, Mimecast)
  # that prefetch links must not produce an error on an account that verified
  # fine — schools and clinics run exactly those scanners.
  it "reports success on a replayed link without double-granting" do
    token = user.generate_email_verification_token!
    verify(token)
    expect(user.reload.tokens).to eq(User::WELCOME_TOKENS)

    verify(token)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["email_verified"]).to be(true)
    expect(user.reload.tokens).to eq(User::WELCOME_TOKENS)
  end

  it "still reports success for an already-verified user past the expiry window" do
    token = user.generate_email_verification_token!
    verify(token)
    user.update!(email_verification_sent_at: 8.days.ago)

    verify(token)

    expect(response).to have_http_status(:ok)
    expect(user.reload.tokens).to eq(User::WELCOME_TOKENS)
  end
end

RSpec.describe "POST /api/resend_email_verification", type: :request do
  let(:user) { FactoryBot.create(:user, confirmed_at: nil) }

  def resend(as_user: user)
    post "/api/resend_email_verification", headers: auth_headers(as_user), as: :json
  end

  it "sends a fresh verification email and rotates the token" do
    original = user.generate_email_verification_token!
    user.update!(email_verification_sent_at: 6.minutes.ago)

    expect { resend }.to have_enqueued_mail(UserMailer, :verify_email)

    expect(response).to have_http_status(:ok)
    expect(user.reload.email_verification_token).not_to eq(original)
  end

  it "sends when nothing has been sent yet" do
    expect { resend }.to have_enqueued_mail(UserMailer, :verify_email)
    expect(response).to have_http_status(:ok)
  end

  it "throttles a second request inside the cooldown" do
    user.generate_email_verification_token!

    expect { resend }.not_to have_enqueued_mail(UserMailer, :verify_email)

    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(response.body)["retry_after"]).to be > 0
  end

  it "refuses when the account is already verified" do
    user.update!(email_verified_at: Time.current)

    expect { resend }.not_to have_enqueued_mail(UserMailer, :verify_email)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires authentication" do
    post "/api/resend_email_verification", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "responds honestly when the mailer enqueue fails, without rotating the token or starting the cooldown" do
    original_token = user.email_verification_token
    original_sent_at = user.email_verification_sent_at

    # Stub deliver_later itself (not UserMailer.verify_email) so the failure
    # happens exactly where it would in production — the Redis push inside
    # deliver_later — rather than before the mailer is ever touched.
    delivery = instance_double(ActionMailer::MessageDelivery)
    allow(UserMailer).to receive(:verify_email).and_return(delivery)
    allow(delivery).to receive(:deliver_later).and_raise(Redis::BaseConnectionError, "connection refused")

    resend

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)["error"]).to be_present
    expect(user.reload.email_verification_token).to eq(original_token)
    expect(user.reload.email_verification_sent_at).to eq(original_sent_at)
  end
end
