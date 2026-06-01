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
