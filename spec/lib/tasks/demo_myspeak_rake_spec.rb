require "rails_helper"
require "rake"

RSpec.describe "demo:myspeak_communicators rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["demo:myspeak_communicators"] }

  def run_task
    task.reenable
    task.invoke
  end

  let(:usernames) { %w[mateo-rivera ava-chen jordan-whitfield] }

  after do
    ENV.delete("USER_ID")
  end

  describe "default demo owner" do
    it "seeds 3 active communicators owned by a pro demo user" do
      run_task

      owner = User.find_by(email: "demo-myspeak@speakanyway.dev")
      expect(owner).to be_present
      expect(owner.plan_type).to eq("pro")
      expect(owner.plan_status).to eq("active")

      comms = ChildAccount.where(username: usernames)
      expect(comms.count).to eq(3)
      expect(comms.pluck(:status).uniq).to eq([ChildAccount::ACTIVE])
      # owner_id is canonical; user_id is set as the legacy alias too.
      expect(comms.pluck(:owner_id).uniq).to eq([owner.id])
      expect(comms.pluck(:user_id).uniq).to eq([owner.id])
    end

    it "stores AAC profile fields on details, round-tripping the integer glp_stage" do
      run_task

      mateo = ChildAccount.find_by(username: "mateo-rivera")
      expect(mateo.details).to include(
        "aac_level" => "emerging",
        "vocab_type" => "core",
        "age_band" => "4-6",
        "glp_stage" => 1,
      )
      expect(mateo.details["glp_stage"]).to be_an(Integer)
    end

    it "populates gated safety data on each communicator's MySpeak profile" do
      run_task

      mateo = ChildAccount.find_by(username: "mateo-rivera")
      profile = mateo.profile
      expect(profile).to be_present
      expect(profile.slug).to eq("mateo-rivera")
      expect(profile.has_safety_info?).to be(true)
      expect(profile.settings["ice_contact_1"]).to include(
        "name" => "Daniela Rivera",
        "phone" => "(216) 555-0142",
        "relationship" => "Mother",
      )
      expect(profile.settings["emergency_notes"]).to be_present
    end

    it "is idempotent — a second run adds no rows and keeps slugs stable" do
      run_task
      first_ids = ChildAccount.where(username: usernames).order(:username).pluck(:id)
      first_slugs = Profile.joins("INNER JOIN child_accounts ON profiles.profileable_id = child_accounts.id")
                           .where(profileable_type: "ChildAccount", child_accounts: { username: usernames })
                           .pluck(:slug).sort

      run_task

      expect(ChildAccount.where(username: usernames).count).to eq(3)
      expect(User.where(email: "demo-myspeak@speakanyway.dev").count).to eq(1)
      expect(ChildAccount.where(username: usernames).order(:username).pluck(:id)).to eq(first_ids)
      second_slugs = Profile.where(profileable_type: "ChildAccount", profileable_id: first_ids).pluck(:slug).sort
      expect(second_slugs).to eq(first_slugs)
    end
  end

  describe "USER_ID override" do
    let!(:existing_owner) { create(:user, plan_type: "pro", plan_status: "active") }

    it "attaches the communicators to the given user instead of the demo owner" do
      ENV["USER_ID"] = existing_owner.id.to_s

      run_task

      expect(ChildAccount.where(username: usernames).pluck(:owner_id).uniq).to eq([existing_owner.id])
      expect(User.where(email: "demo-myspeak@speakanyway.dev")).to be_empty
    end
  end
end
