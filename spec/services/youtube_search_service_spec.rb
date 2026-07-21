require "rails_helper"

RSpec.describe YoutubeSearchService do
  let(:api_key) { "test-key" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return(api_key)
  end

  def stub_youtube(status:, body:)
    stub_request(:get, YoutubeSearchService::BASE_URL)
      .with(query: hash_including(
        "q" => "wheels on the bus",
        "safeSearch" => "strict",
        "videoEmbeddable" => "true",
        "type" => "video",
      ))
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def item(video_id, title: "A Song", channel: "Kids Channel")
    {
      id: { videoId: video_id },
      snippet: {
        title: title,
        channelTitle: channel,
        thumbnails: {
          default: { url: "https://i.ytimg.com/vi/#{video_id}/default.jpg" },
          medium: { url: "https://i.ytimg.com/vi/#{video_id}/mqdefault.jpg" },
        },
      },
    }
  end

  describe "#search" do
    it "returns parsed results with validated ids" do
      stub_youtube(status: 200, body: { items: [item("dQw4w9WgXcQ")] })

      results = described_class.new("wheels on the bus").search

      expect(results).to eq([{
        "youtube_id" => "dQw4w9WgXcQ",
        "title" => "A Song",
        "channel_title" => "Kids Channel",
        "thumbnail_url" => "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg",
      }])
    end

    it "drops items whose video id fails validation" do
      stub_youtube(status: 200, body: {
        items: [item("bad id!"), item(""), item("dQw4w9WgXcQ")],
      })

      results = described_class.new("wheels on the bus").search

      expect(results.map { |r| r["youtube_id"] }).to eq(["dQw4w9WgXcQ"])
    end

    it "falls back to the default thumbnail when medium is missing" do
      no_medium = item("dQw4w9WgXcQ")
      no_medium[:snippet][:thumbnails].delete(:medium)
      stub_youtube(status: 200, body: { items: [no_medium] })

      results = described_class.new("wheels on the bus").search

      expect(results.first["thumbnail_url"])
        .to eq("https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg")
    end

    it "returns an empty array when the API returns no items" do
      stub_youtube(status: 200, body: { items: [] })

      expect(described_class.new("wheels on the bus").search).to eq([])
    end

    it "returns nil on an API error response" do
      stub_youtube(status: 403, body: { error: { message: "quota" } })

      expect(described_class.new("wheels on the bus").search).to be_nil
    end

    it "returns nil on a network failure" do
      stub_request(:get, YoutubeSearchService::BASE_URL)
        .with(query: hash_including("q" => "wheels on the bus"))
        .to_timeout

      expect(described_class.new("wheels on the bus").search).to be_nil
    end

    context "when the API key is not configured" do
      let(:api_key) { nil }

      it "returns nil without making a request" do
        expect(described_class.new("wheels on the bus").search).to be_nil
        expect(a_request(:get, /googleapis/)).not_to have_been_made
      end
    end
  end

  describe ".enabled?" do
    it "is true with a key and false without" do
      expect(described_class.enabled?).to be(true)
      allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return(nil)
      expect(described_class.enabled?).to be(false)
    end
  end
end
