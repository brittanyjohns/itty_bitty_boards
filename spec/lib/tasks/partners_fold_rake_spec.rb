require "rails_helper"
require "rake"

RSpec.describe "partners:fold_into_clinicians rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["partners:fold_into_clinicians"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    saved = ENV.slice("USER_ID", "DRY_RUN", "PARTNER_LOANER_SLOTS")
    example.run
  ensure
    %w[USER_ID DRY_RUN PARTNER_LOANER_SLOTS].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  let!(:partner) do
    FactoryBot.create(:user, plan_type: "partner_pro", role: "partner").tap do |u|
      u.update_columns(stripe_subscription_id: "sub_partner")
    end
  end

  it "does not change anything on a dry run" do
    ENV["USER_ID"] = partner.id.to_s
    expect(Stripe::Subscription).not_to receive(:cancel)
    expect { run_task }.not_to change { partner.reload.plan_type }
  end

  it "folds a partner into clinician, keeps 5 loaner slots, cancels the trial, and re-runs cleanly" do
    ENV["USER_ID"] = partner.id.to_s
    ENV["DRY_RUN"] = "false"
    expect(Stripe::Subscription).to receive(:cancel).with("sub_partner").and_return(true)

    run_task

    partner.reload
    expect(partner.plan_type).to eq("clinician")
    expect(partner.role).to eq("partner")
    # Partners keep 5 loaner slots (override of the clinician 2-slot cap).
    expect(partner.settings["paid_communicator_limit"]).to eq(5)
    expect(partner.stripe_subscription_id).to be_nil
    expect(partner.plan_credits_balance).to eq(400)

    # Idempotent: no longer partner_pro, so a rerun touches nothing.
    expect(Stripe::Subscription).not_to receive(:cancel)
    expect { run_task }.not_to change { partner.reload.plan_type }
  end

  it "gives a non-partner-role partner_pro user the standard 2-slot clinician cap" do
    weird = FactoryBot.create(:user, plan_type: "partner_pro", role: "user")
    ENV["USER_ID"] = weird.id.to_s
    ENV["DRY_RUN"] = "false"

    run_task

    expect(weird.reload.plan_type).to eq("clinician")
    expect(weird.settings["paid_communicator_limit"]).to eq(2)
  end
end
