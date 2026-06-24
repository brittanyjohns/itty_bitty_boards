require "rails_helper"

RSpec.describe DiskSpaceAlertJob, type: :sidekiq do
  let(:job) { described_class.new }

  def perform_with_usage(pct)
    allow(job).to receive(:root_disk_usage_percent).and_return(pct)
    job.perform
  end

  describe "#perform" do
    context "below the warn threshold" do
      it "sends no email" do
        allow(job).to receive(:claim_alert_slot).and_return(true)
        expect { perform_with_usage(75) }.not_to change { ActionMailer::Base.deliveries.size }
      end
    end

    context "at or above the warn threshold" do
      it "emails a WARNING alert" do
        allow(job).to receive(:claim_alert_slot).and_return(true)
        expect { perform_with_usage(85) }.to change { ActionMailer::Base.deliveries.size }.by(1)
        expect(ActionMailer::Base.deliveries.last.subject).to include("WARNING").and(include("85%"))
      end
    end

    context "at or above the critical threshold" do
      it "emails a CRITICAL alert" do
        allow(job).to receive(:claim_alert_slot).and_return(true)
        expect { perform_with_usage(95) }.to change { ActionMailer::Base.deliveries.size }.by(1)
        expect(ActionMailer::Base.deliveries.last.subject).to include("CRITICAL")
      end
    end

    context "when df cannot be read" do
      it "no-ops without raising" do
        allow(job).to receive(:root_disk_usage_percent).and_return(nil)
        expect { job.perform }.not_to change { ActionMailer::Base.deliveries.size }
      end
    end

    context "on staging" do
      # Since #393 staging is its own EC2 box, so it monitors its own disk
      # (no longer skipped — it shared the prod box before).
      it "still alerts when the disk is critical" do
        allow(AppEnv).to receive(:staging?).and_return(true)
        allow(job).to receive(:claim_alert_slot).and_return(true)
        expect { perform_with_usage(95) }.to change { ActionMailer::Base.deliveries.size }.by(1)
      end
    end

    context "when an alert for the severity was already sent" do
      it "does not send a second email until the debounce window passes" do
        allow(job).to receive(:root_disk_usage_percent).and_return(85)
        # claim_alert_slot reserves a Redis slot: true the first time, false
        # while the debounce window is still open.
        allow(job).to receive(:claim_alert_slot).and_return(true, false)

        expect { job.perform }.to change { ActionMailer::Base.deliveries.size }.by(1)
        expect { job.perform }.not_to change { ActionMailer::Base.deliveries.size }
      end
    end
  end
end
