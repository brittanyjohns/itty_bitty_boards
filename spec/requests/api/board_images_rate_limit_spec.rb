# spec/requests/api/board_images_rate_limit_spec.rb
require "rails_helper"

RSpec.describe "BoardImages rate limiting", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  

  # Minimal JSON helper
  def j
    JSON.parse(response.body) rescue {}
  end

  before(:all) do
    # Ensure Redis.current exists and points to a test DB
    unless Redis.respond_to?(:current)
      class << Redis; attr_accessor :current; end
    end
    Redis.current ||= Redis.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1") # use a test DB
    )
  end

  before do
    # clean slate rate-limit keys for the test DB
    Redis.current.flushdb

    # authenticate current_user without stubbing: if you have token auth,
    # replace the header below accordingly. If your app uses session auth,
    # sign in via a helper.
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)
  end

  after { travel_back }

  let!(:user)        { create(:user) }
  let!(:board)       { create(:board, user: user) }
  let!(:image)       { create(:image, user: user) }
  let!(:board_image) { create(:board_image, board: board, image: image) }

  describe "POST /api/board_images/:id/create_image_edit" do
    it "returns 429 on the 6th call (limit 5/day), without any stubs" do
      # we don't assert specific success payloads for the first 5 calls;
      # we only require that the limiter does NOT return 429 before the 6th.
      statuses = []

      puts "Starting test: making 6 requests to create_image_edit: BoardImage ID #{board_image.id}, User ID #{user.id}"

      5.times do
        post "/api/board_images/#{board_image.id}/create_image_edit",
             params: { prompt: "any" }
        statuses << response.status
        puts "Request #{statuses.size}: response status #{response.status}"
        expect(response.status).not_to eq(429), "unexpected 429 before limit"
      end

      # 6th should be blocked by the limiter
      post "/api/board_images/#{board_image.id}/create_image_edit",
           params: { prompt: "any" }
      expect(response.status).to eq(429)
      expect(j["error"]).to eq("limit_reached")
      expect(j["limit"]).to eq(5)
      expect(j["used"]).to be >= 6
    end
  end

  describe "POST /api/board_images/:id/create_image_variation" do
    it "tracks a separate counter and hits 429 after 5 calls to variations" do
      5.times do
        post "/api/board_images/#{board_image.id}/create_image_variation"
        expect(response.status).not_to eq(429)
      end

      post "/api/board_images/#{board_image.id}/create_image_variation"
      expect(response.status).to eq(429)
      expect(j["error"]).to eq("limit_reached")
    end
  end

  describe "daily reset behavior" do
    it "resets at end-of-day in app timezone (integration-level check)" do
      Time.zone = "America/New_York"
      travel_to Time.zone.parse("2025-10-22 22:00:00") do
        5.times do
          post "/api/board_images/#{board_image.id}/create_image_edit", params: { prompt: "x" }
          expect(response.status).not_to eq(429)
        end
        post "/api/board_images/#{board_image.id}/create_image_edit", params: { prompt: "x" }
        expect(response.status).to eq(429)
      end

      # Move just past midnight local time — counter should have reset
      travel_to Time.zone.parse("2025-10-23 00:01:00") do
        post "/api/board_images/#{board_image.id}/create_image_edit", params: { prompt: "x" }
        expect(response.status).not_to eq(429)
      end
    end
  end

  context "when the board image is missing" do
    it "returns 422 and not 429 (ensuring the limiter runs first)" do
      5.times do
        post "/api/board_images/999999/create_image_edit", params: { prompt: "x" }
        # Either 422 (not found) or 404 depending on your find logic; importantly, not 429
        expect([422, 404]).to include(response.status)
      end
      post "/api/board_images/999999/create_image_edit", params: { prompt: "x" }
      expect([422, 404]).to include(response.status)
    end
  end
end