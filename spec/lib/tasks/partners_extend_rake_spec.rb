require "rails_helper"
require "rake"

RSpec.describe "partners:extend rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["partners:extend"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    saved = ENV.slice("USER_ID", "MONTHS", "DRY_RUN")
    example.run
  ensure
    %w[USER_ID MONTHS DRY_RUN].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  let!(:partner) do
    create(:user, plan_type: "partner_pro", role: "partner").tap do |u|
      u.update_columns(stripe_subscription_id: "sub_x", plan_expires_at: 10.days.from_now)
    end
  end

  it "aborts without USER_ID" do
    expect { run_task }.to raise_error(SystemExit)
  end

  it "aborts for a non-partner user" do
    other = create(:user, plan_type: "free")
    ENV["USER_ID"] = other.id.to_s
    expect { run_task }.to raise_error(SystemExit)
  end

  it "does not modify anything on a dry run" do
    ENV["USER_ID"] = partner.id.to_s
    expect(partner).not_to receive(:extend_partner_pro_trial!)
    expect { run_task }.not_to change { partner.reload.plan_expires_at }
  end

  it "extends via the model and clears the once-flags when applied" do
    partner.update!(settings: partner.settings.merge(
      "partner_pilot_ending_notified" => true,
      "partner_pilot_expired" => true,
    ))
    ENV["USER_ID"] = partner.id.to_s
    ENV["MONTHS"] = "3"
    ENV["DRY_RUN"] = "false"

    allow(Stripe::Subscription).to receive(:update).and_return(double(id: "sub_x"))

    run_task

    partner.reload
    expect(partner.plan_expires_at).to be > 80.days.from_now
    expect(partner.settings["partner_pilot_ending_notified"]).to be_nil
    expect(partner.settings["partner_pilot_expired"]).to be_nil
  end
end
