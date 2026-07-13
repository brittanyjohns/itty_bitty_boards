# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "profiles:copy_onboarding_bio_to_emergency_notes rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["profiles:copy_onboarding_bio_to_emergency_notes"] }

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

  # A profile whose onboarding notes were saved into the public bio, with no
  # emergency notes yet — the migration target.
  let!(:target) do
    Profile.new(
      profileable: child,
      username: "emma-jones",
      slug: "emma-jones",
      bio: "Has seizures. Calming phrase: 'you are safe.'",
    ).tap(&:save!)
  end

  before do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  it "previews without changing anything in dry-run (default)" do
    run_task

    target.reload
    expect(target.settings["emergency_notes"]).to be_nil
    expect(target.bio).to include("Has seizures")
  end

  it "copies bio into blank emergency_notes when applied, keeping the bio" do
    ENV["DRY_RUN"] = "false"
    run_task

    target.reload
    expect(target.settings["emergency_notes"]).to eq("Has seizures. Calming phrase: 'you are safe.'")
    # Bio is KEPT — no public page goes blank.
    expect(target.bio).to include("Has seizures")
  end

  it "skips profiles that already have emergency notes" do
    target.update!(settings: target.settings.merge("emergency_notes" => "existing note"))
    ENV["DRY_RUN"] = "false"
    run_task

    expect(target.reload.settings["emergency_notes"]).to eq("existing note")
  end

  it "skips the generated placeholder bio" do
    placeholder_child = FactoryBot.create(:child_account, user: owner, owner: owner, name: "Max")
    placeholder = Profile.new(
      profileable: placeholder_child,
      username: "max-power",
      slug: "max-power",
      bio: "Write a short bio about yourself. This will help others understand who you are and what you do.",
    ).tap(&:save!)

    ENV["DRY_RUN"] = "false"
    run_task

    expect(placeholder.reload.settings["emergency_notes"]).to be_nil
  end

  it "is idempotent — a second run is a no-op" do
    ENV["DRY_RUN"] = "false"
    run_task
    first = target.reload.settings["emergency_notes"]

    run_task
    expect(target.reload.settings["emergency_notes"]).to eq(first)
  end

  it "leaves user (non-child-account) safety-less profiles untouched" do
    page = Profile.new(profileable: owner, profile_kind: "public_page", username: "pat-smith", bio: "hello").tap(&:save!)
    ENV["DRY_RUN"] = "false"
    run_task

    expect(page.reload.settings["emergency_notes"]).to be_nil
  end

  it "scopes to a single user via USER_ID" do
    other_owner = FactoryBot.create(:user)
    other_child = FactoryBot.create(:child_account, user: other_owner, owner: other_owner, name: "Kit")
    other = Profile.new(
      profileable: other_child,
      username: "kit-stone",
      slug: "kit-stone",
      bio: "Loves music.",
    ).tap(&:save!)

    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = owner.id.to_s
    run_task

    expect(target.reload.settings["emergency_notes"]).to include("Has seizures")
    expect(other.reload.settings["emergency_notes"]).to be_nil
  end
end
