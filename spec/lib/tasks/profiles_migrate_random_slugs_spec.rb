# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "profiles:migrate_to_random_slugs rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["profiles:migrate_to_random_slugs"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID")
    example.run
    ENV["DRY_RUN"] = original["DRY_RUN"]
    ENV["USER_ID"] = original["USER_ID"]
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Emma") }
  let!(:safety) do
    Profile.new(profileable: child, username: "emma-jones", slug: "emma-jones").tap(&:save!)
  end

  before do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  it "previews without changing anything or enqueuing jobs in dry-run (default)" do
    expect {
      run_task
    }.not_to have_enqueued_job(RegenerateSafetyCardsJob)

    safety.reload
    expect(safety.slug).to eq("emma-jones")
    expect(safety.slug_type).to eq("legacy")
    expect(safety.legacy_slug).to be_nil
  end

  it "migrates the slug and enqueues card regeneration when applied" do
    ENV["DRY_RUN"] = "false"

    expect {
      run_task
    }.to have_enqueued_job(RegenerateSafetyCardsJob).with(safety.id)

    safety.reload
    expect(safety.slug).to match(/\As-[a-z0-9]{6}\z/)
    expect(safety.slug_type).to eq("random")
    expect(safety.legacy_slug).to eq("emma-jones")
  end

  it "leaves non-safety (public_page) profiles untouched" do
    page = Profile.new(profileable: owner, profile_kind: "public_page", username: "pat-smith").tap(&:save!)
    ENV["DRY_RUN"] = "false"

    run_task

    page.reload
    expect(page.slug).to eq("pat-smith")
    expect(page.slug_type).to eq("legacy")
    expect(page.legacy_slug).to be_nil
  end

  it "does not re-migrate an already-random profile on a second run" do
    ENV["DRY_RUN"] = "false"
    run_task
    first_slug = safety.reload.slug

    expect {
      run_task
    }.not_to have_enqueued_job(RegenerateSafetyCardsJob).with(safety.id)

    expect(safety.reload.slug).to eq(first_slug)
  end

  it "scopes to a single user via USER_ID" do
    other_owner = FactoryBot.create(:user)
    other_child = FactoryBot.create(:child_account, user: other_owner, owner: other_owner, name: "Max")
    other = Profile.new(profileable: other_child, username: "max-power", slug: "max-power").tap(&:save!)

    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = owner.id.to_s
    run_task

    expect(safety.reload.slug_type).to eq("random")
    expect(other.reload.slug_type).to eq("legacy")
    expect(other.slug).to eq("max-power")
  end
end
