# frozen_string_literal: true

require "rails_helper"

# Issue #214 — PATCH /api/profiles/:id is owner-only when the profile
# belongs to a ChildAccount (the Safety / Emergency profile). The SLP
# supervisor who is on the team but is not the owner cannot edit it.
# Spec: marketing/.claude-notes/handoff-workflow.md (Permissions matrix).
RSpec.describe "API::Profiles owner protection", type: :request do
  let(:slp)    { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }
  let(:parent) { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }
  let(:admin)  { create(:user, role: "admin", created_at: 2.months.ago) }

  # Post-claim shape: parent owns the communicator, SLP stays on the team
  # as a supervisor.
  let!(:account) do
    create(:child_account,
           user: parent,
           owner: parent,
           status: ChildAccount::ACTIVE,
           passcode: "ownerpw1")
  end
  let!(:team) do
    t = account.ensure_team!(creator: slp)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t
  end
  let!(:child_profile) do
    Profile.create!(
      profileable: account,
      username: "safety-#{SecureRandom.hex(2)}",
      slug: "safety-#{SecureRandom.hex(2)}",
    )
  end

  # The safety profile triggers Grover/puppeteer-driven PNG generation
  # on update; that's out of scope for an authorization spec and isn't
  # available in CI.
  before do
    allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    allow_any_instance_of(Profile).to receive(:enqueue_audio_job_if_needed).and_return(true)
  end

  describe "PATCH /api/profiles/:id (ChildAccount safety profile)" do
    let(:update_params) { { profile: { bio: "Updated bio" } } }

    it "allows the parent owner to update" do
      patch "/api/profiles/#{child_profile.id}",
            params: update_params,
            headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
    end

    it "blocks the SLP supervisor with 403 not_owner" do
      patch "/api/profiles/#{child_profile.id}",
            params: update_params,
            headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_owner")
    end

    it "allows a system admin to update" do
      patch "/api/profiles/#{child_profile.id}",
            params: update_params,
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end
  end

  # The asset endpoints hand back an UNSIGNED CloudFront URL for an artifact
  # that prints allergies, medications and emergency contacts. Authentication
  # was never enough here — the id is the only thing standing between a signed-in
  # stranger and another family's emergency info, and ids are sequential.
  describe "communicator asset endpoints" do
    let(:fake_attachment) { instance_double(ActiveStorage::Attached::One, attached?: true) }

    before do
      allow(Communicators::GenerateSafetyIdCard).to receive(:call).and_return(true)
      allow(Communicators::GenerateDeviceTag).to receive(:call).and_return(true)
      allow(Communicators::GenerateScanTag).to receive(:call).and_return(true)
      allow_any_instance_of(Profile).to receive(:safety_id_png).and_return(fake_attachment)
      allow_any_instance_of(Profile).to receive(:device_tag_png).and_return(fake_attachment)
      allow_any_instance_of(Profile).to receive(:scan_tag_png).and_return(fake_attachment)
      allow_any_instance_of(Profile).to receive(:url_for_attachment)
        .and_return("https://cdn.example.test/asset.png")
    end

    describe "POST /api/profiles/:id/safety_id" do
      it "allows the parent owner" do
        post "/api/profiles/#{child_profile.id}/safety_id", headers: auth_headers(parent)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["url"]).to be_present
      end

      it "blocks the SLP supervisor with 403 not_owner" do
        post "/api/profiles/#{child_profile.id}/safety_id", headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      end

      # The guard is a before_action for this reason: a non-owner must not be
      # able to trigger a render (or a regenerate) on someone else's profile,
      # even if the URL were withheld from the response.
      it "does not generate anything for a non-owner" do
        post "/api/profiles/#{child_profile.id}/safety_id",
             params: { regenerate: true },
             headers: auth_headers(slp)

        expect(Communicators::GenerateSafetyIdCard).not_to have_received(:call)
      end

      it "never leaks the asset URL to a non-owner" do
        post "/api/profiles/#{child_profile.id}/safety_id", headers: auth_headers(slp)

        expect(response.body).not_to include("cdn.example.test")
      end

      it "allows a system admin" do
        post "/api/profiles/#{child_profile.id}/safety_id", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
      end
    end

    describe "POST /api/profiles/:id/device_tag" do
      it "allows the parent owner" do
        post "/api/profiles/#{child_profile.id}/device_tag", headers: auth_headers(parent)

        expect(response).to have_http_status(:ok)
      end

      it "blocks the SLP supervisor with 403 not_owner" do
        post "/api/profiles/#{child_profile.id}/device_tag", headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      end
    end

    # The scan tag prints only a QR and a line of text, but that QR resolves to
    # the same MySpeak page as the other two — so it is gated identically.
    describe "POST /api/profiles/:id/scan_tag" do
      it "allows the parent owner" do
        post "/api/profiles/#{child_profile.id}/scan_tag", headers: auth_headers(parent)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["url"]).to be_present
      end

      it "blocks the SLP supervisor with 403 not_owner" do
        post "/api/profiles/#{child_profile.id}/scan_tag", headers: auth_headers(slp)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      end

      it "does not generate anything for a non-owner" do
        post "/api/profiles/#{child_profile.id}/scan_tag",
             params: { regenerate: true },
             headers: auth_headers(slp)

        expect(Communicators::GenerateScanTag).not_to have_received(:call)
      end

      it "never leaks the asset URL to a non-owner" do
        post "/api/profiles/#{child_profile.id}/scan_tag", headers: auth_headers(slp)

        expect(response.body).not_to include("cdn.example.test")
      end

      it "allows a system admin" do
        post "/api/profiles/#{child_profile.id}/scan_tag", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
      end

      it "serves the PDF when format_type=pdf" do
        allow_any_instance_of(Profile).to receive(:scan_tag_pdf).and_return(fake_attachment)

        post "/api/profiles/#{child_profile.id}/scan_tag",
             params: { format_type: "pdf" },
             headers: auth_headers(parent)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["url"]).to be_present
      end
    end

    # `profileable` is optional: true, so a profile can outlive its
    # communicator. Fail closed with a 403 rather than raising on nil.
    it "refuses an orphaned profile instead of raising" do
      child_profile.update_columns(profileable_id: nil)

      post "/api/profiles/#{child_profile.id}/safety_id", headers: auth_headers(parent)

      expect(response).to have_http_status(:forbidden)
    end

    describe "a User-owned profile" do
      let(:slp_profile) do
        Profile.create!(
          profileable: slp,
          username: "slp-#{SecureRandom.hex(2)}",
          slug: "slp-#{SecureRandom.hex(2)}",
        )
      end

      it "allows the user to generate their own device tag" do
        post "/api/profiles/#{slp_profile.id}/device_tag", headers: auth_headers(slp)

        expect(response).to have_http_status(:ok)
      end

      it "blocks another user from generating it" do
        post "/api/profiles/#{slp_profile.id}/device_tag", headers: auth_headers(parent)

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      end
    end
  end

  describe "PATCH /api/profiles/:id (User-owned profile)" do
    let(:user_profile) do
      Profile.create!(
        profileable: parent,
        username: "u-#{SecureRandom.hex(2)}",
        slug: "u-#{SecureRandom.hex(2)}",
      )
    end

    it "allows the user to update their own profile" do
      patch "/api/profiles/#{user_profile.id}",
            params: { profile: { bio: "My bio" } },
            headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
    end
  end
end
