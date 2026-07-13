require "rails_helper"

RSpec.describe MailchimpService do
  let(:client) { double("MailchimpClient") }
  let(:journeys) { double("customerJourneys") }
  let(:user) { FactoryBot.build(:user, email: "parent@example.com") }

  before do
    allow(MailchimpClient).to receive(:client).and_return(client)
    # Gem accessor is camelCase `customerJourneys` (no snake_case alias).
    allow(client).to receive(:customerJourneys).and_return(journeys)
  end

  describe "#record_new_subscriber" do
    let(:lists) { double("lists") }
    let(:hash) { Digest::MD5.hexdigest("parent@example.com") }

    before do
      allow(client).to receive(:lists).and_return(lists)
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_AUDIENCE_ID" => "aud_123"))
    end

    it "still applies tags when the contact already exists in the audience" do
      allow(lists).to receive(:get_list_member).with("aud_123", hash).and_return({ "id" => hash })

      expect(lists).not_to receive(:set_list_member)
      expect(lists).to receive(:update_list_member_tags).with(
        "aud_123",
        hash,
        { tags: [
          { name: "Partner Program", status: "active" },
          { name: "PartnerPro_Jul", status: "active" },
          { name: "FreePlan", status: "active" },
        ] },
      )

      described_class.new.record_new_subscriber(user, tags: ["Partner Program", "PartnerPro_Jul"])
    end

    it "creates the contact and applies tags when it doesn't exist yet" do
      not_found = MailchimpMarketing::ApiError.new(status: 404)
      allow(lists).to receive(:get_list_member).with("aud_123", hash).and_raise(not_found)

      expect(lists).to receive(:set_list_member).with(
        "aud_123",
        hash,
        hash_including(email_address: "parent@example.com", status: "subscribed"),
      ).and_return({ "id" => hash })
      expect(lists).to receive(:update_list_member_tags).with(
        "aud_123",
        hash,
        { tags: [
          { name: "Partner Program", status: "active" },
          { name: "FreePlan", status: "active" },
        ] },
      )

      described_class.new.record_new_subscriber(user, tags: ["Partner Program"])
    end

    it "swallows Mailchimp API errors and returns nil" do
      allow(lists).to receive(:get_list_member)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500))

      expect(described_class.new.record_new_subscriber(user, tags: ["Partner Program"])).to be_nil
    end
  end

  describe "#record_lead" do
    let(:lists) { double("lists") }

    before do
      allow(client).to receive(:lists).and_return(lists)
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_AUDIENCE_ID" => "aud_123"))
    end

    it "upserts the raw email as subscribed with FNAME and applies tags" do
      hash = Digest::MD5.hexdigest("lead@example.com")

      expect(lists).to receive(:set_list_member).with(
        "aud_123",
        hash,
        {
          email_address: "lead@example.com",
          status_if_new: "subscribed",
          merge_fields: { FNAME: "Jamie" },
        },
      )
      expect(lists).to receive(:update_list_member_tags).with(
        "aud_123",
        hash,
        { tags: [{ name: "BoardDownloadLead", status: "active" }] },
      )

      described_class.new.record_lead(email: "lead@example.com", name: "Jamie", tags: ["BoardDownloadLead"])
    end

    it "omits FNAME and the tags call when name and tags are blank" do
      hash = Digest::MD5.hexdigest("lead@example.com")

      expect(lists).to receive(:set_list_member).with(
        "aud_123",
        hash,
        {
          email_address: "lead@example.com",
          status_if_new: "subscribed",
          merge_fields: {},
        },
      )
      expect(lists).not_to receive(:update_list_member_tags)

      described_class.new.record_lead(email: "lead@example.com")
    end
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

    # Regression guard for the NoMethodError that the mocked tests above can't
    # catch: the real MailchimpMarketing::Client exposes the journeys API as
    # camelCase `customerJourneys`, with no snake_case `customer_journeys`.
    # Using the wrong name 500s every trigger in production.
    it "calls the gem's real camelCase journeys accessor" do
      bare_client = MailchimpMarketing::Client.new
      expect(bare_client).to respond_to(:customerJourneys)
      expect(bare_client).not_to respond_to(:customer_journeys)
    end

    context "when the journeys accessor is missing or shape-changed" do
      it "returns nil without raising when the client exposes no journeys accessor" do
        allow(client).to receive(:respond_to?).with(:customerJourneys).and_return(false)
        allow(client).to receive(:respond_to?).with(:customer_journeys).and_return(false)

        service = described_class.new
        expect(Rails.logger).to receive(:error).with(/Customer Journeys API unavailable/)
        expect {
          expect(service.trigger_journey(user, journey_id: 10, step_id: 20)).to be_nil
        }.not_to raise_error
      end

      it "swallows a NoMethodError from the trigger call instead of crashing the job" do
        allow(journeys).to receive(:trigger).and_raise(NoMethodError.new("undefined method `trigger'"))

        service = described_class.new
        expect(Rails.logger).to receive(:error).with(/Customer Journeys accessor unavailable/)
        expect {
          expect(service.trigger_journey(user, journey_id: 10, step_id: 20)).to be_nil
        }.not_to raise_error
      end

      it "falls back to a snake_case accessor if a future gem only exposes that" do
        snake_journeys = double("customer_journeys")
        allow(client).to receive(:respond_to?).with(:customerJourneys).and_return(false)
        allow(client).to receive(:respond_to?).with(:customer_journeys).and_return(true)
        allow(client).to receive(:customer_journeys).and_return(snake_journeys)
        expect(snake_journeys).to receive(:trigger).with(10, 20, { email_address: "parent@example.com" })

        described_class.new.trigger_journey(user, journey_id: 10, step_id: 20)
      end
    end
  end

  describe "#archive_subscriber" do
    let(:lists) { double("lists") }
    let(:user) { FactoryBot.build(:user, id: 42, email: "doomed@example.com") }

    before do
      allow(client).to receive(:lists).and_return(lists)
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_AUDIENCE_ID" => "aud_123"))
    end

    it "tags the contact as AccountDeleted and unsubscribes them" do
      hash = Digest::MD5.hexdigest("doomed@example.com")

      expect(lists).to receive(:update_list_member_tags).with(
        "aud_123",
        hash,
        { tags: [
          { name: "AccountDeleted", status: "active" },
          { name: "deleted:user_requested", status: "active" },
        ] },
      )
      expect(lists).to receive(:update_list_member).with(
        "aud_123",
        hash,
        { status: "unsubscribed" },
      )

      expect(described_class.new.archive_subscriber(user, reason: "user_requested")).to eq(true)
    end

    it "returns true and logs when the subscriber is not found (404)" do
      allow(lists).to receive(:update_list_member_tags)
      allow(lists).to receive(:update_list_member)
        .and_raise(MailchimpMarketing::ApiError.new(status: 404, message: "Not Found"))

      expect(described_class.new.archive_subscriber(user)).to eq(true)
    end

    it "returns false on other API errors" do
      allow(lists).to receive(:update_list_member_tags)
      allow(lists).to receive(:update_list_member)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect(described_class.new.archive_subscriber(user)).to eq(false)
    end
  end

  describe "#delete_subscriber_permanently" do
    let(:lists) { double("lists") }
    let(:user) { FactoryBot.build(:user, id: 42, email: "gone@example.com") }

    before do
      allow(client).to receive(:lists).and_return(lists)
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_AUDIENCE_ID" => "aud_123"))
    end

    it "permanently deletes the subscriber" do
      hash = Digest::MD5.hexdigest("gone@example.com")
      expect(lists).to receive(:delete_list_member_permanent).with("aud_123", hash)

      expect(described_class.new.delete_subscriber_permanently(user)).to eq(true)
    end

    it "returns true when the subscriber does not exist (404)" do
      allow(lists).to receive(:delete_list_member_permanent)
        .and_raise(MailchimpMarketing::ApiError.new(status: 404, message: "Not Found"))

      expect(described_class.new.delete_subscriber_permanently(user)).to eq(true)
    end

    it "returns false on other API errors" do
      allow(lists).to receive(:delete_list_member_permanent)
        .and_raise(MailchimpMarketing::ApiError.new(status: 500, message: "boom"))

      expect(described_class.new.delete_subscriber_permanently(user)).to eq(false)
    end
  end
end
