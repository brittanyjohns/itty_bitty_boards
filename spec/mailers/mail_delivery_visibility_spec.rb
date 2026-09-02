# frozen_string_literal: true

require "rails_helper"

# #820 — the first clinician applicant on an external domain received none of
# four transactional emails while an intra-domain control received all of them,
# and the app had no signal either way. These are the two signals: a line when
# the transport accepts a message (carrying the Message-ID a Google Workspace
# Email Log Search takes) and a tagged line when delivery raises.
RSpec.describe "mail delivery visibility" do
  describe MailDeliveryObserver do
    def message_to(address)
      Mail.new(from: "noreply@speakanyway.com", to: address, subject: "Hello", body: "hi").tap do |m|
        m.message_id = "<test-#{SecureRandom.hex(4)}@speakanyway.com>"
      end
    end

    it "logs the recipient, subject and Message-ID of a delivered message" do
      message = message_to("someone@gmail.com")

      expect(Rails.logger).to receive(:info).with(
        a_string_matching(/\[mail\] delivered .*to=someone@gmail\.com.*message_id=.*test-/)
      )

      described_class.delivered_email(message)
    end

    it "stays silent when an interceptor suppressed the send" do
      message = message_to("e2e+run-1@speakanyway.com")
      message.perform_deliveries = false

      expect(Rails.logger).not_to receive(:info)

      described_class.delivered_email(message)
    end

    it "records a delivered row carrying the Message-ID an Email Log Search takes" do
      message = message_to("someone@gmail.com")

      expect { described_class.delivered_email(message) }.to change(MailDelivery, :count).by(1)

      row = MailDelivery.last
      expect(row).to have_attributes(
        status: MailDelivery::DELIVERED,
        recipients: "someone@gmail.com",
        subject: "Hello",
      )
      expect(row.message_id).to eq(message.message_id)
    end

    it "records a suppressed row rather than nothing, naming why" do
      message = message_to("e2e+run-1@speakanyway.com")
      message.perform_deliveries = false

      expect { described_class.delivered_email(message) }.to change(MailDelivery, :count).by(1)
      expect(MailDelivery.last).to have_attributes(
        status: MailDelivery::SUPPRESSED,
        reason: "e2e_recipient",
      )
    end

    it "never breaks a send that already succeeded when recording raises" do
      allow(MailDelivery).to receive(:record).and_raise(ActiveRecord::StatementInvalid, "db gone")

      expect { described_class.delivered_email(message_to("someone@gmail.com")) }.not_to raise_error
    end

    it "records nothing when the kill switch is off" do
      allow(MailDelivery).to receive(:recording_enabled?).and_return(false)

      expect { described_class.delivered_email(message_to("someone@gmail.com")) }
        .not_to change(MailDelivery, :count)
    end
  end

  describe "ApplicationMailer delivery failures" do
    # A mailer that raises the way a rejected SMTP session does.
    let(:failing_mailer) do
      Class.new(ApplicationMailer) do
        def self.name = "FailingTestMailer"

        def boom
          mail(to: "someone@gmail.com", subject: "Boom") { |f| f.text { raise Net::SMTPFatalError, "550 rejected" } }
        end
      end
    end

    it "logs a tagged line naming the recipient, then re-raises" do
      expect(Rails.logger).to receive(:error).with(
        a_string_matching(/\[mail\] delivery_failed mailer=FailingTestMailer#boom .*Net::SMTPFatalError/)
      )

      expect { failing_mailer.boom.deliver_now }.to raise_error(Net::SMTPFatalError)
    end

    it "records a failed row an admin can see, and still re-raises" do
      expect { failing_mailer.boom.deliver_now }
        .to raise_error(Net::SMTPFatalError)
        .and change(MailDelivery, :count).by(1)

      expect(MailDelivery.last).to have_attributes(
        status: MailDelivery::FAILED,
        mailer: "FailingTestMailer#boom",
        error_class: "Net::SMTPFatalError",
      )
      expect(MailDelivery.last.error_message).to include("550 rejected")
    end

    it "re-raises the original error even when recording the failure raises" do
      allow(MailDelivery).to receive(:record).and_raise(ActiveRecord::StatementInvalid, "db gone")

      expect { failing_mailer.boom.deliver_now }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe MailDelivery do
    it "prunes rows past the retention window and keeps the rest" do
      old_row = described_class.record(status: described_class::DELIVERED)
      old_row.update_columns(created_at: (described_class.retention_days + 1).days.ago)
      kept = described_class.record(status: described_class::DELIVERED)

      expect { described_class.prune! }.to change(described_class, :count).by(-1)
      expect(described_class.exists?(kept.id)).to be(true)
    end

    it "truncates a pathological header rather than refusing to record" do
      message = Mail.new(to: "a@b.com", subject: "x" * 900)

      row = described_class.record(status: described_class::DELIVERED, message: message)

      expect(row.subject.length).to eq(described_class::COLUMN_LIMIT)
    end

    it "returns nil instead of raising when the write fails" do
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "db gone")

      expect(described_class.record(status: described_class::DELIVERED)).to be_nil
    end
  end
end
