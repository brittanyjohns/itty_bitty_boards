require "rails_helper"
require "rake"

RSpec.describe "partners:restart rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["partners:restart"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    saved = ENV.slice("IDS", "MONTHS", "STAGGER_DAYS", "DRY_RUN", "STRIPE_PRICE_PARTNER_PRO")
    ENV["STRIPE_PRICE_PARTNER_PRO"] = "price_partner_test"
    example.run
  ensure
    %w[IDS MONTHS STAGGER_DAYS DRY_RUN].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  before do
    allow(MailchimpService).to receive(:new)
      .and_return(instance_double(MailchimpService, record_new_subscriber: true))
  end

  it "aborts without IDS" do
    expect { run_task }.to raise_error(SystemExit)
  end

  it "does not change anything on a dry run" do
    partner = create(:user, plan_type: "pro", role: "partner")
    ENV["IDS"] = partner.id.to_s
    expect(Stripe::Subscription).not_to receive(:create)

    expect { run_task }.not_to change { partner.reload.plan_type }
  end

  context "when applied" do
    it "cancels the stale sub, creates a fresh trial, and resets to partner_pro" do
      partner = create(:user, plan_type: "free", role: "partner", stripe_customer_id: "cus_x")
      partner.update_columns(stripe_subscription_id: "sub_stale")
      partner.update!(settings: partner.settings.merge("partner_pilot_expired" => true))

      ENV["IDS"] = partner.id.to_s
      ENV["DRY_RUN"] = "false"

      expect(Stripe::Subscription).to receive(:cancel).with("sub_stale")
      expect(Stripe::Subscription).to receive(:create).and_return(double(id: "sub_new"))

      run_task

      partner.reload
      expect(partner.plan_type).to eq("partner_pro")
      expect(partner.stripe_subscription_id).to eq("sub_new")
      expect(partner.plan_expires_at).to be > 80.days.from_now
      expect(partner.settings["partner_pilot_expired"]).to be_nil
    end

    it "staggers trial ends across multiple partners" do
      p1 = create(:user, plan_type: "pro", role: "partner", stripe_customer_id: "cus_1")
      p2 = create(:user, plan_type: "pro", role: "partner", stripe_customer_id: "cus_2")
      ENV["IDS"] = "#{p1.id},#{p2.id}"
      ENV["STAGGER_DAYS"] = "3"
      ENV["DRY_RUN"] = "false"
      allow(Stripe::Subscription).to receive(:create).and_return(double(id: "sub_a"), double(id: "sub_b"))

      run_task

      # Second partner's trial ends later than the first (staggered).
      expect(p2.reload.plan_expires_at).to be > p1.reload.plan_expires_at
    end
  end
end
