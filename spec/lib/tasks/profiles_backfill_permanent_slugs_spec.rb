# frozen_string_literal: true

require "rails_helper"
require "rake"

# `permanent_slug` is what a printed QR resolves through, so every profile that
# predates the column needs one — after which its device tag, care plan and
# safety card stop depending on a public slug the owner can change or revoke.
RSpec.describe "profiles:backfill_permanent_slugs rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["profiles:backfill_permanent_slugs"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN")
    example.run
    ENV["DRY_RUN"] = original["DRY_RUN"]
  end

  before { ENV.delete("DRY_RUN") }

  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Emma") }
  let!(:profile) do
    Profile.new(profileable: child, username: "emma-jones").tap(&:save!).tap do |p|
      p.update_columns(permanent_slug: nil)
    end
  end

  it "changes nothing in dry-run (the default)" do
    run_task
    expect(profile.reload.permanent_slug).to be_nil
  end

  it "assigns a permanent slug when applied" do
    ENV["DRY_RUN"] = "false"
    run_task

    expect(profile.reload.permanent_slug).to match(/\As-[a-z0-9]{6}\z/)
    # Distinct from the public slug — that separation is the whole point.
    expect(profile.permanent_slug).not_to eq(profile.slug)
  end

  it "never regenerates one that already exists, so a re-run is a no-op" do
    ENV["DRY_RUN"] = "false"
    run_task
    assigned = profile.reload.permanent_slug

    run_task

    expect(profile.reload.permanent_slug).to eq(assigned)
  end

  it "covers user public pages too, not just communicator pages" do
    page = Profile.new(profileable: owner, profile_kind: "public_page", username: "pat-smith")
                  .tap(&:save!)
    page.update_columns(permanent_slug: nil)

    ENV["DRY_RUN"] = "false"
    run_task

    expect(page.reload.permanent_slug).to match(/\As-[a-z0-9]{6}\z/)
  end

  # A row carrying a slug the current format rules would reject must still get
  # its permanent slug — the task writes with update_columns for this reason.
  it "backfills a row whose stored slug would fail validation" do
    profile.update_columns(slug: "Bad_Slug!!")

    ENV["DRY_RUN"] = "false"
    run_task

    expect(profile.reload.permanent_slug).to match(/\As-[a-z0-9]{6}\z/)
  end
end
