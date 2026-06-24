require "rails_helper"

RSpec.describe IpGeolocation do
  describe ".coarse" do
    it "returns nil for blank / private / loopback IPs without calling the provider" do
      expect(Geocoder).not_to receive(:search)
      expect(described_class.coarse(nil)).to be_nil
      expect(described_class.coarse("127.0.0.1")).to be_nil
      expect(described_class.coarse("10.0.0.5")).to be_nil
      expect(described_class.coarse("192.168.1.10")).to be_nil
    end

    it "returns a coarse hash with a human label for a resolvable IP" do
      result = double("geo", city: "Austin", state: "Texas", country: "US")
      allow(Geocoder).to receive(:search).and_return([result])

      out = described_class.coarse("8.8.8.8")
      expect(out).to eq(
        city: "Austin", region: "Texas", country: "US", label: "Austin, Texas, US"
      )
    end

    it "returns nil when the provider yields no result" do
      allow(Geocoder).to receive(:search).and_return([])
      expect(described_class.coarse("8.8.8.8")).to be_nil
    end

    it "never raises — provider errors become nil" do
      allow(Geocoder).to receive(:search).and_raise(StandardError, "boom")
      expect(described_class.coarse("8.8.8.8")).to be_nil
    end

    it "builds a partial label when some fields are missing" do
      result = double("geo", city: "Berlin", state: nil, country: "DE")
      allow(Geocoder).to receive(:search).and_return([result])
      expect(described_class.coarse("8.8.8.8")[:label]).to eq("Berlin, DE")
    end
  end
end
