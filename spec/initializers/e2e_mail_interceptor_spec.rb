require "rails_helper"

RSpec.describe E2eMailInterceptor do
  def message_to(*recipients)
    Mail::Message.new.tap { |m| m.to = recipients }
  end

  it "blocks delivery when every recipient is an e2e address" do
    message = message_to("e2e+local123-1@speakanyway.com")
    described_class.delivering_email(message)
    expect(message.perform_deliveries).to be false
  end

  it "is case-insensitive and handles multiple e2e recipients" do
    message = message_to("E2E+Run-9@SpeakAnyWay.com", "e2e+x@speakanyway.com")
    described_class.delivering_email(message)
    expect(message.perform_deliveries).to be false
  end

  it "strips e2e addresses but still delivers to real recipients" do
    message = message_to("parent@example.com", "e2e+run-1@speakanyway.com")
    described_class.delivering_email(message)
    expect(message.perform_deliveries).to be true
    expect(message.to).to eq(["parent@example.com"])
  end

  it "leaves ordinary mail untouched" do
    message = message_to("parent@example.com")
    described_class.delivering_email(message)
    expect(message.perform_deliveries).to be true
    expect(message.to).to eq(["parent@example.com"])
  end

  it "does not match lookalike domains or missing plus tags" do
    %w[e2e@speakanyway.com e2e+x@speakanyway.com.evil.com someone+e2e@speakanyway.com].each do |addr|
      message = message_to(addr)
      described_class.delivering_email(message)
      expect(message.perform_deliveries).to be(true), "expected #{addr} to deliver"
    end
  end
end
