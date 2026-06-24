# frozen_string_literal: true

require "rails_helper"

# Issue #384 — viewing a public safety page enqueues a view-log / parent-alert
# job. The job itself is unit-tested in spec/sidekiq; here we only assert the
# controller wiring: safety pages enqueue, others don't, and an enqueue failure
# never breaks the public page.
RSpec.describe "GET /api/profiles/public/:slug view logging", type: :request do
  let(:owner) { FactoryBot.create(:user, email: "parent-view@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }

  def safety_profile
    Profile.create!(profileable: child, username: "sky-safety", slug: "sky-safety")
  end

  before { RecordProfileViewJob.jobs.clear }

  it "enqueues a view-log job for a safety profile" do
    profile = safety_profile

    expect {
      get "/api/profiles/public/#{profile.slug}"
    }.to change { RecordProfileViewJob.jobs.size }.by(1)

    expect(response).to have_http_status(:ok)
    args = RecordProfileViewJob.jobs.last["args"]
    expect(args.first).to eq(profile.id)
  end

  it "does not enqueue for a pro public_page profile" do
    profile = Profile.new(profileable: child, username: "sky-pro", slug: "sky-pro")
    profile.profile_kind = "public_page"
    profile.save!

    expect {
      get "/api/profiles/public/#{profile.slug}"
    }.not_to change { RecordProfileViewJob.jobs.size }
  end

  it "does not enqueue for an unclaimed placeholder" do
    placeholder = Profile.create!(
      username: "ph-1", slug: "ph-1", placeholder: true,
      claim_token: SecureRandom.hex(8), claimed_at: nil,
    )

    expect {
      get "/api/profiles/public/#{placeholder.slug}"
    }.not_to change { RecordProfileViewJob.jobs.size }
  end

  it "still serves the page when enqueue raises" do
    profile = safety_profile
    allow(RecordProfileViewJob).to receive(:perform_async).and_raise(StandardError, "redis down")

    get "/api/profiles/public/#{profile.slug}"

    expect(response).to have_http_status(:ok)
  end
end
