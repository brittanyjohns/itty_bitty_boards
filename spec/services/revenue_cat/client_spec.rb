require "rails_helper"

RSpec.describe RevenueCat::Client do
  describe "#verified_plan_for" do
    it "returns ok?: false when the API key is unconfigured" do
      result = described_class.new(api_key: nil).verified_plan_for("123")
      expect(result.ok?).to be(false)
      expect(result.error).to eq("missing_api_key")
    end

    context "with a configured key" do
      let(:client) { described_class.new(api_key: "sk_test") }
      let(:conn) { instance_double(Faraday::Connection) }

      before { allow(client).to receive(:connection).and_return(conn) }

      def stub_response(status:, body:)
        allow(conn).to receive(:get).and_return(instance_double(Faraday::Response, status: status, body: body.to_json))
      end

      it "resolves the plan_type and latest expiration from active entitlements" do
        expiry = (Time.current + 20.days)
        stub_response(status: 200, body: {
          "subscriber" => { "entitlements" => { "pro" => { "expires_date" => expiry.utc.iso8601 } } },
        })

        result = client.verified_plan_for("123")
        expect(result.ok?).to be(true)
        expect(result.plan_type).to eq("pro")
        expect(result.expiration).to be_within(2.seconds).of(expiry)
      end

      it "ignores expired entitlements" do
        stub_response(status: 200, body: {
          "subscriber" => { "entitlements" => { "pro" => { "expires_date" => 2.days.ago.utc.iso8601 } } },
        })

        result = client.verified_plan_for("123")
        expect(result.ok?).to be(true)
        expect(result.plan_type).to be_nil
      end

      it "returns ok?: false on a non-200 response" do
        stub_response(status: 404, body: {})
        expect(client.verified_plan_for("123").ok?).to be(false)
      end
    end
  end
end
