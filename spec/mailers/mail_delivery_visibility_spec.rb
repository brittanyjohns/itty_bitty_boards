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
  end
end
