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

    it "applies free-plan limits, including the sandbox + claimable slots" do
      run_task

      settings = myspeak_user.reload.settings
      expect(settings["demo_communicator_limit"]).to eq(1)
      # Free can host 1 claimed loaner/active (paid_communicator_limit=1).
      expect(settings["paid_communicator_limit"]).to eq(1)
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

  describe "plans:backfill_communicator_limits" do
    let(:task) { Rake::Task["plans:backfill_communicator_limits"] }

    def zero_settings(plan)
      {
        "paid_communicator_limit" => 0,
        "demo_communicator_limit" => 0,
        "board_limit" => 0,
        "ai_monthly_limit" => 0,
        "plan_nickname" => plan,
      }
    end

    it "fills zero/missing limits for a Pro user without clobbering higher values" do
      pro = create(:user, plan_type: "pro", created_at: 2.months.ago, settings: zero_settings("pro"))
      # Admin-bumped slot we must preserve.
      pro.update!(settings: pro.settings.merge("paid_communicator_limit" => 10))

      run_task

      settings = pro.reload.settings
      expect(settings["paid_communicator_limit"]).to eq(10) # preserved
      expect(settings["demo_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["demo_communicator_limit"])
      expect(settings["board_limit"]).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(settings["ai_monthly_limit"]).to eq(User::PRO_PLAN_LIMITS["ai_monthly_limit"])
    end

    it "fills the new Free paid_communicator_limit=1 onto legacy Free users" do
      free = create(:user, plan_type: "free", created_at: 1.year.ago)
      free.update!(settings: free.settings.merge("paid_communicator_limit" => 0))

      run_task

      expect(free.reload.settings["paid_communicator_limit"]).to eq(1)
    end

    it "applies Pro defaults to partner_pro users" do
      partner = create(:user, plan_type: "partner_pro", created_at: 2.months.ago, settings: zero_settings("partner_pro"))

      run_task

      settings = partner.reload.settings
      expect(settings["paid_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["paid_communicator_limit"])
      expect(settings["demo_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["demo_communicator_limit"])
    end

    it "is idempotent — second run makes no further changes" do
      pro = create(:user, plan_type: "pro", created_at: 2.months.ago, settings: zero_settings("pro"))

      run_task
      first = pro.reload.settings.dup

      task.reenable
      task.invoke
      expect(pro.reload.settings).to eq(first)
    end

    it "honors DRY_RUN by reporting but not writing" do
      pro = create(:user, plan_type: "pro", created_at: 2.months.ago, settings: zero_settings("pro"))

      ENV["DRY_RUN"] = "true"
      begin
        expect { run_task }.not_to(change { pro.reload.settings["paid_communicator_limit"] })
      ensure
        ENV.delete("DRY_RUN")
      end
    end

    it "skips users on an unknown plan_type" do
      mystery = create(:user, plan_type: "experimental_x", created_at: 2.months.ago, settings: zero_settings("experimental_x"))

      run_task

      expect(mystery.reload.settings["paid_communicator_limit"]).to eq(0)
    end
  end
end
