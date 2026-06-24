# frozen_string_literal: true

require "rails_helper"

# Issue #384 — the safety-view log + parent alert fire when someone deliberately
# opens the emergency info (POST public/:slug/safety_view), NOT on page-open.
# The job itself is unit-tested in spec/sidekiq; here we assert the controller
# wiring: page-open never enqueues and never leaks sensitive data, the gated
# endpoint enqueues + returns the sensitive payload, and an enqueue failure
# never breaks the reveal.
RSpec.describe "Safety-profile view alerts", type: :request do
  let(:owner) { FactoryBot.create(:user, email: "parent-view@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }

  let(:sensitive_settings) do
    {
      "allergies" => "peanuts",
      "medications" => "epipen",
      "emergency_notes" => "prone to seizures",
      "device_notes" => "charger is USB-C",
      "pronouns" => "she/her",
      "ice_contact_1" => { "name" => "Mom", "phone" => "555-1234", "relationship" => "Parent" },
    }
  end

  def safety_profile(settings: sensitive_settings)
    Profile.create!(
      profileable: child, username: "sky-safety", slug: "sky-safety", settings: settings,
    )
  end

  before { RecordProfileViewJob.jobs.clear }

  describe "GET /api/profiles/public/:slug (page-open)" do
    it "does NOT enqueue a view-log job for a safety profile" do
      profile = safety_profile

      expect {
        get "/api/profiles/public/#{profile.slug}"
      }.not_to change { RecordProfileViewJob.jobs.size }

      expect(response).to have_http_status(:ok)
    end

    it "withholds medical info + emergency contacts from the page payload" do
      profile = safety_profile

      get "/api/profiles/public/#{profile.slug}"

      body = JSON.parse(response.body)
      settings = body["settings"]
      # Page-safe fields stay.
      expect(settings).to include("pronouns" => "she/her", "device_notes" => "charger is USB-C")
      # Sensitive fields are gone.
      expect(settings).not_to have_key("allergies")
      expect(settings).not_to have_key("medications")
      expect(settings).not_to have_key("emergency_notes")
      expect(settings).not_to have_key("ice_contact_1")
      # The raw values never appear anywhere in the response.
      expect(response.body).not_to include("peanuts")
      expect(response.body).not_to include("555-1234")
      # But the frontend is told there IS info to reveal.
      expect(body["has_safety_info"]).to be(true)
    end

    it "reports has_safety_info=false when only page-safe settings exist" do
      profile = safety_profile(settings: { "pronouns" => "they/them" })

      get "/api/profiles/public/#{profile.slug}"

      expect(JSON.parse(response.body)["has_safety_info"]).to be(false)
    end
  end

  describe "POST /api/profiles/public/:slug/safety_view (emergency info opened)" do
    it "enqueues a view-log job and returns the sensitive payload" do
      profile = safety_profile

      expect {
        post "/api/profiles/public/#{profile.slug}/safety_view"
      }.to change { RecordProfileViewJob.jobs.size }.by(1)

      expect(response).to have_http_status(:ok)
      args = RecordProfileViewJob.jobs.last["args"]
      expect(args.first).to eq(profile.id)

      settings = JSON.parse(response.body)["settings"]
      expect(settings).to include(
        "allergies" => "peanuts",
        "medications" => "epipen",
        "emergency_notes" => "prone to seizures",
      )
      expect(settings["ice_contact_1"]).to include("name" => "Mom", "phone" => "555-1234")
      # Page-safe-only keys are not duplicated into the gated payload.
      expect(settings).not_to have_key("pronouns")
    end

    it "records every access (job enqueued per call) for the audit trail" do
      profile = safety_profile

      expect {
        post "/api/profiles/public/#{profile.slug}/safety_view"
        post "/api/profiles/public/#{profile.slug}/safety_view"
      }.to change { RecordProfileViewJob.jobs.size }.by(2)
    end

    it "still reveals the info when enqueue raises" do
      profile = safety_profile
      allow(RecordProfileViewJob).to receive(:perform_async).and_raise(StandardError, "redis down")

      post "/api/profiles/public/#{profile.slug}/safety_view"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["settings"]).to include("allergies" => "peanuts")
    end

    it "404s for an unknown slug" do
      post "/api/profiles/public/does-not-exist/safety_view"
      expect(response).to have_http_status(:not_found)
    end

    it "does not enqueue or reveal for a pro public_page profile" do
      profile = Profile.new(profileable: child, username: "sky-pro", slug: "sky-pro", settings: sensitive_settings)
      profile.profile_kind = "public_page"
      profile.save!

      expect {
        post "/api/profiles/public/#{profile.slug}/safety_view"
      }.not_to change { RecordProfileViewJob.jobs.size }

      expect(response).to have_http_status(:not_found)
    end
  end
end
