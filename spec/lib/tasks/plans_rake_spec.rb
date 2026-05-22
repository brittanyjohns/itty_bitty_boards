require "rails_helper"
require "rake"

RSpec.describe "plans rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["plans:migrate_myspeak_to_free"] }

  def run_task
    task.reenable
    task.invoke
  end

  describe "plans:migrate_myspeak_to_free" do
    let!(:myspeak_user) do
      create(:user, plan_type: "myspeak", plan_status: "pending", created_at: 2.months.ago)
    end
    let!(:myspeak_yearly_user) do
      create(:user, plan_type: "myspeak_yearly", created_at: 2.months.ago)
    end
    let!(:basic_user) do
      create(:user, plan_type: "basic", created_at: 2.months.ago)
    end

    it "moves myspeak and myspeak_yearly users onto the free plan" do
      run_task

      expect(myspeak_user.reload.plan_type).to eq("free")
      expect(myspeak_yearly_user.reload.plan_type).to eq("free")
      expect(myspeak_user.plan_status).to eq("active")
    end

    it "applies free-plan limits, including the demo-communicator slot" do
      run_task

      settings = myspeak_user.reload.settings
      expect(settings["demo_communicator_limit"]).to eq(1)
      expect(settings["board_limit"]).to eq(1)
      expect(settings["plan_nickname"]).to eq("free")
    end

    it "leaves other plans untouched" do
      run_task

      expect(basic_user.reload.plan_type).to eq("basic")
    end

    it "is idempotent" do
      run_task
      expect { run_task }.not_to raise_error
      expect(myspeak_user.reload.plan_type).to eq("free")
    end
  end
end
