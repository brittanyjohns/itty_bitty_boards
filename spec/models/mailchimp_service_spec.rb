require "rails_helper"

RSpec.describe MailchimpService do
  let(:client) { double("MailchimpClient") }
  let(:journeys) { double("customer_journeys") }
  let(:user) { FactoryBot.build(:user, email: "parent@example.com") }

  before do
    allow(MailchimpClient).to receive(:client).and_return(client)
    allow(client).to receive(:customer_journeys).and_return(journeys)
  end

  describe "#update_merge_fields" do
    let(:lists) { double("lists") }

    before do
      allow(client).to receive(:lists).and_return(lists)
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_AUDIENCE_ID" => "aud_123"))
    end

    it "upserts the contact's merge fields by subscriber hash" do
      hash = Digest::MD5.hexdigest("parent@example.com")
      expect(lists).to receive(:set_list_member).with(
        "aud_123",
        hash,
        {
          email_address: "parent@example.com",
          status_if_new: "subscribed",
          merge_fields: { "BOARDS" => "3" },
        },
      )

      described_class.new.update_merge_fields(user, { "BOARDS" => "3" })
    end

    it "swallows Mailchimp API errors and returns nil" do
      allow(lists).to receive(:set_list_member)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect(described_class.new.update_merge_fields(user, { "BOARDS" => "3" })).to be_nil
    end
  end

  describe "#trigger_journey" do
    it "triggers the journey for the contact by email" do
      expect(journeys).to receive(:trigger).with(10, 20, { email_address: "parent@example.com" })

      described_class.new.trigger_journey(user, journey_id: 10, step_id: 20)
    end

    it "upserts the contact and retries once when Mailchimp 404s" do
      service = described_class.new
      allow(service).to receive(:record_new_subscriber).and_return(true)

      calls = 0
      allow(journeys).to receive(:trigger) do
        calls += 1
        raise MailchimpMarketing::ApiError.new(status: 404, message: "Not Found") if calls == 1
        :ok
      end

      expect(service.trigger_journey(user, journey_id: 10, step_id: 20)).to eq(:ok)
      expect(service).to have_received(:record_new_subscriber).once
      expect(calls).to eq(2)
    end

    it "does not loop forever when the upsert can't make the contact eligible" do
      service = described_class.new
      allow(service).to receive(:record_new_subscriber).and_return(nil)
      allow(journeys).to receive(:trigger)
        .and_raise(MailchimpMarketing::ApiError.new(status: 404, message: "Not Found"))

      expect(service.trigger_journey(user, journey_id: 10, step_id: 20)).to be_nil
      expect(journeys).to have_received(:trigger).once
    end

    it "logs and returns nil on other API errors" do
      service = described_class.new
      allow(journeys).to receive(:trigger)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect(Rails.logger).to receive(:error).with(/Failed to trigger journey 10\/20/)
      expect(service.trigger_journey(user, journey_id: 10, step_id: 20)).to be_nil
    end
  end
end
