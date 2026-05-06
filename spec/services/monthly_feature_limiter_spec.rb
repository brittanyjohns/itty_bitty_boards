require "rails_helper"

RSpec.describe MonthlyFeatureLimiter, type: :service do
  let(:user_id) { 42 }
  let(:redis)   { instance_double(Redis) }

  before { allow(Redis).to receive(:current).and_return(redis) }

  describe "#key" do
    it "includes the user id, feature, and current year-month stamp" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_edits)
      stamp   = Time.current.in_time_zone("UTC").strftime("%Y%m")
      expect(limiter.key).to eq("rl:#{user_id}:image_edits:#{stamp}")
    end

    it "accepts a custom timestamp" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_edits)
      fixed   = Time.new(2025, 3, 15)
      expect(limiter.key(fixed)).to eq("rl:#{user_id}:image_edits:202503")
    end
  end

  describe "#feature_name" do
    it "returns 'Image Edits' for image_edits" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_edits)
      expect(limiter.feature_name(:image_edits)).to eq("Image Edits")
    end

    it "returns 'Image Variations' for image_variations" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_variations)
      expect(limiter.feature_name(:image_variations)).to eq("Image Variations")
    end

    it "humanizes unknown keys" do
      limiter = described_class.new(user_id: user_id, feature_key: :some_feature)
      expect(limiter.feature_name(:some_feature)).to eq("Some feature")
    end
  end

  describe "#check!" do
    let(:limiter) { described_class.new(user_id: user_id, feature_key: :image_edits, limit: 5) }

    it "returns allowed=true when usage is below the limit" do
      allow(redis).to receive(:get).and_return("3")
      allowed, meta = limiter.check!
      expect(allowed).to be true
      expect(meta[:remaining]).to eq(2)
      expect(meta[:used]).to eq(3)
      expect(meta[:limit]).to eq(5)
    end

    it "returns allowed=false when usage equals the limit" do
      allow(redis).to receive(:get).and_return("5")
      allowed, = limiter.check!
      expect(allowed).to be false
    end

    it "returns remaining of 0 when usage exceeds the limit" do
      allow(redis).to receive(:get).and_return("7")
      _allowed, meta = limiter.check!
      expect(meta[:remaining]).to eq(0)
    end

    it "treats a missing Redis key (nil) as zero usage" do
      allow(redis).to receive(:get).and_return(nil)
      allowed, meta = limiter.check!
      expect(allowed).to be true
      expect(meta[:used]).to eq(0)
    end
  end

  describe "#increment_and_check!" do
    let(:limiter) { described_class.new(user_id: user_id, feature_key: :image_edits, limit: 5) }

    context "on first use (count becomes 1)" do
      before do
        allow(redis).to receive(:incr).and_return(1)
        allow(redis).to receive(:expireat)
      end

      it "sets an expiry on the key" do
        expect(redis).to receive(:expireat)
        limiter.increment_and_check!
      end

      it "returns allowed=true" do
        allowed, = limiter.increment_and_check!
        expect(allowed).to be true
      end
    end

    context "when count is within the limit" do
      before do
        allow(redis).to receive(:incr).and_return(3)
      end

      it "does not set an expiry" do
        expect(redis).not_to receive(:expireat)
        expect(redis).not_to receive(:expire)
        limiter.increment_and_check!
      end

      it "returns allowed=true and correct remaining count" do
        allowed, meta = limiter.increment_and_check!
        expect(allowed).to be true
        expect(meta[:remaining]).to eq(2)
      end
    end

    context "when count equals the limit exactly" do
      before { allow(redis).to receive(:incr).and_return(5) }

      it "returns allowed=true (at-limit is still allowed)" do
        allowed, = limiter.increment_and_check!
        expect(allowed).to be true
      end
    end

    context "when count exceeds the limit" do
      before { allow(redis).to receive(:incr).and_return(6) }

      it "returns allowed=false" do
        allowed, = limiter.increment_and_check!
        expect(allowed).to be false
      end

      it "reports remaining as 0" do
        _allowed, meta = limiter.increment_and_check!
        expect(meta[:remaining]).to eq(0)
      end
    end

    context "with a rolling window (non-month)" do
      let(:rolling) { described_class.new(user_id: user_id, feature_key: :image_edits, limit: 5, window: :rolling) }

      before do
        allow(redis).to receive(:incr).and_return(1)
        allow(redis).to receive(:expire)
      end

      it "uses expire (TTL) instead of expireat (absolute)" do
        expect(redis).to receive(:expire)
        rolling.increment_and_check!
      end
    end
  end

  describe "#limit_reached?" do
    let(:limiter) { described_class.new(user_id: user_id, feature_key: :image_edits, limit: 5) }

    it "returns false when usage is below the limit" do
      allow(redis).to receive(:get).and_return("2")
      expect(limiter.limit_reached?).to be false
    end

    it "returns true when usage equals or exceeds the limit" do
      allow(redis).to receive(:get).and_return("5")
      expect(limiter.limit_reached?).to be true
    end
  end

  describe "#reset_limit!" do
    let(:limiter) { described_class.new(user_id: user_id, feature_key: :image_edits) }

    it "deletes the Redis key" do
      expect(redis).to receive(:del).with(limiter.key)
      limiter.reset_limit!
    end
  end

  describe "#reset_at" do
    it "returns end of current month for a monthly window" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_edits, window: :month)
      expect(limiter.reset_at).to be_within(1.second).of(Time.current.end_of_month)
    end

    it "returns approximately DEFAULT_TIME from now for a non-month window" do
      limiter = described_class.new(user_id: user_id, feature_key: :image_edits, window: :rolling)
      expected = MonthlyFeatureLimiter::DEFAULT_TIME.from_now
      expect(limiter.reset_at).to be_within(2.seconds).of(expected)
    end
  end
end
