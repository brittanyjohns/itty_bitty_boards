require "rails_helper"

# Part B (email-verification gap): image_generation is deliberately free for
# first-time fills (API::ImagesController#generate only calls check_credits!
# when the image already has a displayable picture — see .claude-notes/credits.md
# "image_generation is free for first-time fills"). That free path never
# touches CreditService, so an unverified account holding zero tokens and
# zero AI credits could still drive paid OpenAI generation for empty tiles.
# require_verified_email! closes that hole.
RSpec.describe "API::Images#generate email verification gate", type: :request do
  def auth(user)
    auth_headers(user)
  end

  describe "unverified user" do
    let(:user) { FactoryBot.create(:user, confirmed_at: nil) }

    it "gets 403 with the email_verification_required error code on the free first-fill path" do
      expect {
        post "/api/images/generate",
             params: { image: { label: "cat", image_prompt: "cat" } },
             headers: auth(user)
      }.not_to change(GenerateImageJob.jobs, :size)

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("email_verification_required")
      # Generic, user-facing only — no internals leaked.
      expect(body["message"]).to be_a(String)
      expect(body).not_to have_key("backtrace")
    end

    it "gets the same 403 even when replacing an existing image (billed path never reached)" do
      allow_any_instance_of(Image).to receive(:display_image_url).and_return("https://example.com/cat.png")

      expect {
        post "/api/images/generate",
             params: { image: { label: "cat", image_prompt: "cat" } },
             headers: auth(user)
      }.not_to change(GenerateImageJob.jobs, :size)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("email_verification_required")
    end
  end

  describe "verified user" do
    let(:user) { FactoryBot.create(:user, confirmed_at: Time.current) }

    before { reset_user_credits!(user) }

    it "can generate a first-time fill for free (no existing image, zero credit balance)" do
      expect(user.reload.plan_credits_balance).to eq(0)

      expect {
        post "/api/images/generate",
             params: { image: { label: "cat", image_prompt: "cat" } },
             headers: auth(user)
      }.to change(GenerateImageJob.jobs, :size).by(1)

      expect(response).not_to have_http_status(:forbidden)
      expect(response).not_to have_http_status(402)
      expect(user.reload.plan_credits_balance).to eq(0) # first fill is not billed
    end

    it "still enforces check_credits! unchanged when replacing an existing image (already-billed path)" do
      # No credits granted — the billed (replace/customize) path must still 402
      # exactly as it did before this change, since the user is verified.
      allow_any_instance_of(Image).to receive(:display_image_url).and_return("https://example.com/cat.png")

      expect {
        post "/api/images/generate",
             params: { image: { label: "cat", image_prompt: "cat" } },
             headers: auth(user)
      }.not_to change(GenerateImageJob.jobs, :size)

      expect(response).to have_http_status(402)
      expect(JSON.parse(response.body)["error"]).to eq("insufficient_credits")
    end

    it "spends credits and generates when replacing an existing image with a healthy balance" do
      CreditService.grant_plan!(user, amount: 1000, period_end: 30.days.from_now)
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
  end
end
