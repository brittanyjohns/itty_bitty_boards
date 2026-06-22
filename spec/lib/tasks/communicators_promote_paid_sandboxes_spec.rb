# frozen_string_literal: true

require "rails_helper"
require "rake"

# Backfill task for issue #359 — promote paid users' stuck sandbox
# communicators to full `active` accounts.
RSpec.describe "communicators:promote_paid_sandboxes rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["communicators:promote_paid_sandboxes"] }

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

  # A paid user whose communicator is stuck in sandbox (created while Free, then
  # upgraded without the reconcile ever running).
  let!(:paid_user) { create(:user, plan_type: "basic") }
  let!(:stuck_sandbox) do
    create(:child_account, user: paid_user, status: ChildAccount::SANDBOX, passcode: nil)
  end

  it "previews without changing anything in dry-run (default)" do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
    run_task
    expect(stuck_sandbox.reload.status).to eq("sandbox")
  end

  it "promotes the sandbox to active when applied" do
    ENV["DRY_RUN"] = "false"
    ENV.delete("USER_ID")
    run_task

    stuck_sandbox.reload
    expect(stuck_sandbox.status).to eq("active")
    expect(stuck_sandbox.passcode).to be_present
  end

  it "leaves Free users' sandboxes untouched" do
    free_user = create(:user, plan_type: "free")
    free_sandbox = create(:child_account, user: free_user, status: ChildAccount::SANDBOX, passcode: nil)

    ENV["DRY_RUN"] = "false"
    ENV.delete("USER_ID")
    run_task

    expect(free_sandbox.reload.status).to eq("sandbox")
  end

  it "leaves Pro users' sandboxes untouched (Pro is entitled to a sandbox slot)" do
    pro_user = create(:user, plan_type: "pro")
    pro_sandbox = create(:child_account, user: pro_user, status: ChildAccount::SANDBOX, passcode: nil)

    ENV["DRY_RUN"] = "false"
    ENV.delete("USER_ID")
    run_task

    expect(pro_sandbox.reload.status).to eq("sandbox")
  end

  it "scopes to a single user via USER_ID" do
    other_paid = create(:user, plan_type: "basic")
    other_sandbox = create(:child_account, user: other_paid, status: ChildAccount::SANDBOX, passcode: nil)

    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = paid_user.id.to_s
    run_task

    expect(stuck_sandbox.reload.status).to eq("active")
    expect(other_sandbox.reload.status).to eq("sandbox")
  end
end
