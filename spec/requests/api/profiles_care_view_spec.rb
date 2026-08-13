# frozen_string_literal: true

require "rails_helper"

# The care-sections reveal (POST public/:slug/care_view) mirrors the emergency
# reveal's shape — withheld on page-open, returned only by the deliberate action
# — but carries a DIFFERENT notification contract: the access is logged and the
# parent is not alerted. These specs pin both halves of that, since the whole
# point of a separate endpoint is the alert it doesn't send.
RSpec.describe "MySpeak care sections", type: :request do
  let(:owner) { FactoryBot.create(:user, email: "parent-care@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }

  let(:care_settings) do
    {
      "pronouns" => "she/her",
      "allergies" => "peanuts",
      "care" => {
        "order" => %w[communication c_7f3a91],
        "sections" => {
          "communication" => {
            "enabled" => true,
            "values" => { "methods" => %w[aac_device gestures], "what_helps" => %w[wait_and_pause] },
          },
          "c_7f3a91" => {
            "custom" => true,
            "title" => "Bedtime",
            "items" => [{ "label" => "Lights out", "value" => "7:30, door left open" }],
          },
        },
      },
    }
  end

  def safety_profile(settings: care_settings, slug: "sky-care")
    Profile.create!(profileable: child, username: slug, slug: slug, settings: settings)
  end

  before { RecordProfileViewJob.jobs.clear }

  describe "GET /api/profiles/public/:slug (page-open)" do
    it "advertises care without shipping any of it" do
      profile = safety_profile

      get "/api/profiles/public/#{profile.slug}"

      body = JSON.parse(response.body)
      expect(body["has_care_info"]).to be(true)
      expect(body["settings"]).not_to have_key("care")
      # The values themselves appear nowhere in the open response.
      expect(response.body).not_to include("7:30, door left open")
      expect(response.body).not_to include("wait_and_pause")
    end

    it "reports has_care_info=false when no care section is filled in" do
      profile = safety_profile(settings: { "pronouns" => "they/them" })

      get "/api/profiles/public/#{profile.slug}"

      expect(JSON.parse(response.body)["has_care_info"]).to be(false)
    end

    it "does not enqueue a view-log job" do
      profile = safety_profile

      expect {
        get "/api/profiles/public/#{profile.slug}"
      }.not_to change { RecordProfileViewJob.jobs.size }
    end
  end

  describe "POST /api/profiles/public/:slug/care_view" do
    it "returns the care blob and logs the access as a care view" do
      profile = safety_profile

      expect {
        post "/api/profiles/public/#{profile.slug}/care_view"
      }.to change { RecordProfileViewJob.jobs.size }.by(1)

      expect(response).to have_http_status(:ok)
      expect(RecordProfileViewJob.jobs.last["args"]).to eq([profile.id, "127.0.0.1", nil, "care"])

      sections = JSON.parse(response.body).dig("settings", "care", "sections")
      expect(sections["communication"]["values"]).to include("what_helps" => %w[wait_and_pause])
      expect(sections["c_7f3a91"]["title"]).to eq("Bedtime")
    end

    it "never leaks emergency info through the care endpoint" do
      profile = safety_profile

      post "/api/profiles/public/#{profile.slug}/care_view"

      expect(JSON.parse(response.body)["settings"].keys).to eq(%w[care])
      expect(response.body).not_to include("peanuts")
    end

    it "still reveals the sections when enqueue raises" do
      profile = safety_profile
      allow(RecordProfileViewJob).to receive(:perform_async).and_raise(StandardError, "redis down")

      post "/api/profiles/public/#{profile.slug}/care_view"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("settings", "care", "sections")).to have_key("communication")
    end

    it "404s for an unknown slug" do
      post "/api/profiles/public/does-not-exist/care_view"
      expect(response).to have_http_status(:not_found)
    end

    it "does not enqueue or reveal for a pro public_page profile" do
      profile = Profile.new(profileable: child, username: "sky-pro", slug: "sky-pro", settings: care_settings)
      profile.profile_kind = "public_page"
      profile.save!

      expect {
        post "/api/profiles/public/#{profile.slug}/care_view"
      }.not_to change { RecordProfileViewJob.jobs.size }

      expect(response).to have_http_status(:not_found)
    end
  end
end
