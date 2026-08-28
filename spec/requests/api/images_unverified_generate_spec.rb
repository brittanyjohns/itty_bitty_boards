require "rails_helper"

# Email verification no longer gates AI. `#generate` used to answer 403
# `email_verification_required` for an unverified caller, because the initial
# credit grant was deferred to verification and the free first-fill path never
# calls check_credits! — so a zero balance couldn't stop it on its own. Credits
# are now granted at signup (User#grant_signup_ai_allowance) and the ledger is
# the only gate on this route. These specs pin that: an unverified account is
# treated exactly like a verified one, and the billed path still 402s on an
# empty balance.
RSpec.describe "API::Images#generate for an unverified account", type: :request do
  def auth(user)
    auth_headers(user)
  end

  let(:user) { FactoryBot.create(:user, email_verified_at: nil) }

  it "generates a first-time fill for free" do
    reset_user_credits!(user)

    expect {
      post "/api/images/generate",
           params: { image: { label: "cat", image_prompt: "cat" } },
           headers: auth(user)
    }.to change(GenerateImageJob.jobs, :size).by(1)

    expect(response).not_to have_http_status(:forbidden)
    expect(response).not_to have_http_status(402)
    expect(user.reload.plan_credits_balance).to eq(0) # first fill is not billed
  end

  it "never answers email_verification_required" do
    post "/api/images/generate",
         params: { image: { label: "cat", image_prompt: "cat" } },
         headers: auth(user)

    expect(response).not_to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).not_to eq("email_verification_required")
  end

  it "spends credits and generates when replacing an existing image" do
    allow_any_instance_of(Image).to receive(:display_image_url).and_return("https://example.com/cat.png")

    expect {
      post "/api/images/generate",
           params: { image: { label: "cat", image_prompt: "cat" } },
           headers: auth(user)
    }.to change { user.reload.plan_credits_balance }.by(-3)
     .and change(GenerateImageJob.jobs, :size).by(1)

    expect(response).not_to have_http_status(:forbidden)
    expect(response).not_to have_http_status(402)
  end

  it "still 402s on the billed path with an empty balance" do
    reset_user_credits!(user)
    allow_any_instance_of(Image).to receive(:display_image_url).and_return("https://example.com/cat.png")

    expect {
      post "/api/images/generate",
           params: { image: { label: "cat", image_prompt: "cat" } },
           headers: auth(user)
    }.not_to change(GenerateImageJob.jobs, :size)

    expect(response).to have_http_status(402)
    expect(JSON.parse(response.body)["error"]).to eq("insufficient_credits")
  end
end
