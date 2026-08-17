require "rails_helper"

RSpec.describe Etsy::Client do
  subject(:client) do
    described_class.new(
      keystring: "KEY", shared_secret: "SECRET", client_id: "CLIENT", shop_id: "42",
    )
  end

  let!(:credential) do
    OauthCredential.create!(provider: OauthCredential::PROVIDER_ETSY, refresh_token: "old-refresh")
  end

  let(:token_url) { described_class::OAUTH_TOKEN_URL }
  let(:api) { described_class::API_BASE }

  def stub_token_exchange(access: "access-1", refresh: "rotated-1", expires_in: 3600)
    stub_request(:post, token_url).to_return(
      status: 200,
      body: { access_token: access, refresh_token: refresh, expires_in: expires_in }.to_json,
      headers: { "Content-Type" => "application/json" },
    )
  end

  describe "OAuth" do
    it "persists the ROTATED refresh token, not just the access token" do
      # Etsy invalidates the token used in the exchange. Failing to write the
      # new one back means every later publish is permanently 403.
      stub_token_exchange
      stub_request(:get, "#{api}/seller-taxonomy/nodes").to_return(status: 200, body: { results: [] }.to_json)

      client.taxonomy_ids

      credential.reload
      expect(credential.refresh_token).to eq("rotated-1")
      expect(credential.access_token).to eq("access-1")
      expect(credential.access_token_expires_at).to be_present
    end

    it "reuses a cached access token instead of burning another refresh" do
      credential.update!(access_token: "cached", access_token_expires_at: 1.hour.from_now)
      stub_request(:get, "#{api}/seller-taxonomy/nodes").to_return(status: 200, body: { results: [] }.to_json)

      client.taxonomy_ids

      expect(a_request(:post, token_url)).not_to have_been_made
    end

    it "raises a configuration error when no credential is stored" do
      credential.destroy!
      expect { client.taxonomy_ids }.to raise_error(described_class::ConfigurationError, /seed_refresh_token/)
    end
  end

  describe "#create_listing" do
    before do
      stub_token_exchange
      stub_request(:post, "#{api}/shops/42/listings")
        .to_return(status: 201, body: { listing_id: 987, url: "https://etsy.test/987" }.to_json)
    end

    def create!(tags: ["aac", "printable"])
      client.create_listing(title: "T", description: "D", price: 5.0, tags: tags)
    end

    it "creates a DRAFT download listing and never an active one" do
      expect(create!()).to eq(listing_id: 987, url: "https://etsy.test/987")

      expect(a_request(:post, "#{api}/shops/42/listings").with { |req|
        params = Rack::Utils.parse_nested_query(req.body)
        params["state"] == "draft" && params["type"] == "download"
      }).to have_been_made
    end

    it "sends tags as ONE comma-separated value" do
      # Repeated `tags` params are not merged by Etsy — it keeps only the last
      # and silently drops the rest.
      create!(tags: ["aac", "printable", "slp"])

      expect(a_request(:post, "#{api}/shops/42/listings").with { |req|
        req.body.scan(/(?:^|&)tags=/).length == 1 &&
          Rack::Utils.parse_nested_query(req.body)["tags"] == "aac,printable,slp"
      }).to have_been_made
    end

    it "drops tags Etsy would silently reject" do
      create!(tags: ["aac", "talking communication board", "for the"])

      expect(a_request(:post, "#{api}/shops/42/listings").with { |req|
        Rack::Utils.parse_nested_query(req.body)["tags"] == "aac"
      }).to have_been_made
    end

    it "sends the api key in the keystring:secret form Etsy enforces" do
      create!()
      expect(a_request(:post, "#{api}/shops/42/listings")
        .with(headers: { "x-api-key" => "KEY:SECRET" })).to have_been_made
    end

    it "raises with the response body when Etsy rejects the listing" do
      stub_request(:post, "#{api}/shops/42/listings")
        .to_return(status: 400, body: "& can only be use once")

      expect { create!() }.to raise_error(described_class::Error, /400.*can only be use once/)
    end
  end

  describe "#set_listing_price" do
    before { stub_token_exchange }

    it "writes through the inventory endpoint, which is the only writer that sticks" do
      stub_request(:get, "#{api}/listings/987/inventory").to_return(
        status: 200,
        body: {
          products: [{ sku: "s", property_values: [], offerings: [{ price: { amount: 100 }, quantity: 999, is_enabled: true }] }],
          price_on_property: [],
        }.to_json,
      )
      stub_request(:put, "#{api}/listings/987/inventory").to_return(status: 200, body: "{}")

      client.set_listing_price(987, 4.5)

      expect(a_request(:put, "#{api}/listings/987/inventory").with { |req|
        JSON.parse(req.body).dig("products", 0, "offerings", 0, "price") == 4.5
      }).to have_been_made
    end

    it "raises rather than silently leaving the price unset when there is no inventory" do
      stub_request(:get, "#{api}/listings/987/inventory")
        .to_return(status: 200, body: { products: [] }.to_json)

      expect { client.set_listing_price(987, 4.5) }
        .to raise_error(described_class::Error, /no inventory products/)
    end
  end

  describe "#assert_known_taxonomy!" do
    before { stub_token_exchange }

    it "raises on an id that isn't in Etsy's taxonomy" do
      # Etsy accepts an unknown id, returns 200, and files the listing under an
      # arbitrary category — so it has to fail here or not at all.
      stub_request(:get, "#{api}/seller-taxonomy/nodes")
        .to_return(status: 200, body: { results: [{ id: 2078, children: [] }] }.to_json)

      expect { client.assert_known_taxonomy!(6816) }
        .to raise_error(described_class::Error, /not a node in Etsy's seller taxonomy/)
      expect(client.assert_known_taxonomy!(2078)).to be true
    end

    it "does not block a publish when the taxonomy fetch itself fails" do
      stub_request(:get, "#{api}/seller-taxonomy/nodes").to_return(status: 503, body: "nope")

      expect(client.assert_known_taxonomy!(2078)).to be true
    end
  end

  describe "#upload_file" do
    before { stub_token_exchange }

    it "refuses a file over Etsy's 20 MB cap instead of failing mid-upload" do
      expect {
        client.upload_file(987, bytes: "x" * (described_class::FILE_CAP_BYTES + 1), filename: "big.pdf")
      }.to raise_error(described_class::Error, /caps a download file at 20 MB/)
    end

    it "posts multipart with the normalized name" do
      stub_request(:post, "#{api}/shops/42/listings/987/files").to_return(status: 201, body: "{}")

      client.upload_file(987, bytes: "pdf-bytes", filename: "core words (set).pdf")

      expect(a_request(:post, "#{api}/shops/42/listings/987/files").with { |req|
        req.headers["Content-Type"].to_s.start_with?("multipart/form-data") &&
          req.body.include?("core-words-set-.pdf")
      }).to have_been_made
    end
  end

  describe "#upload_video" do
    before { stub_token_exchange }

    it "posts multipart to the listing's own video endpoint" do
      stub_request(:post, "#{api}/shops/42/listings/987/videos").to_return(status: 201, body: "{}")

      client.upload_video(987, bytes: "mp4-bytes", filename: "flip through.mp4")

      expect(a_request(:post, "#{api}/shops/42/listings/987/videos").with { |req|
        req.headers["Content-Type"].to_s.start_with?("multipart/form-data") &&
          req.body.include?('name="video"') &&
          req.body.include?('name="name"') &&
          req.body.include?("flip-through.mp4")
      }).to have_been_made
    end

    it "refuses a clip over Etsy's 100 MB cap instead of failing mid-upload" do
      expect {
        client.upload_video(987, bytes: "x" * (described_class::VIDEO_CAP_BYTES + 1), filename: "big.mp4")
      }.to raise_error(described_class::Error, /caps a listing video at 100 MB/)
    end

    # Etsy allows one video per listing, and its `video_id` field replaces it.
    # This app only ever creates fresh drafts, so there is nothing to replace
    # and nothing to delete — and a DELETE against a live listing is what the
    # drafts-only invariant exists to prevent.
    it "has no list or delete counterpart" do
      expect(described_class.instance_methods)
        .not_to include(:list_listing_videos, :delete_listing_video)
    end
  end

  describe "#normalize_filename" do
    it "keeps only the characters Etsy allows" do
      expect(client.normalize_filename("Core Words! v2.pdf")).to eq("Core-Words-v2.pdf")
    end

    it "pads a name shorter than Etsy's 3-character minimum" do
      expect(client.normalize_filename("a")).to eq("file-a")
    end
  end

  describe ".configured?" do
    it "is false without a stored refresh token" do
      credential.update!(refresh_token: nil)
      expect(client.configured?).to be false
    end

    it "is false when the env is incomplete" do
      expect(described_class.new(keystring: nil, shared_secret: "S", client_id: "C", shop_id: "1").configured?)
        .to be false
    end

    it "is true with env plus a stored token" do
      expect(client.configured?).to be true
    end
  end
end
