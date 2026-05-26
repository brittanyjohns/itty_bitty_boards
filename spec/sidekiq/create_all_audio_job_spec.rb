require "rails_helper"

RSpec.describe CreateAllAudioJob, type: :job do
  describe "retry backoff" do
    let(:retry_block) { described_class.sidekiq_retry_in_block }

    it "backs off 30s+ on Polly throttling so the queue can drain" do
      err = Aws::Polly::Errors::ThrottlingException.new(nil, "Rate exceeded")
      delay = retry_block.call(0, err)
      expect(delay).to be >= 30
      expect(delay).to be < 60
    end

    it "increases the backoff on later attempts" do
      err = Aws::Polly::Errors::ThrottlingException.new(nil, "Rate exceeded")
      first = retry_block.call(0, err)
      later = retry_block.call(3, err)
      expect(later).to be > first
    end

    it "falls back to Sidekiq default for unrelated errors" do
      expect(retry_block.call(0, StandardError.new("boom"))).to be_nil
    end
  end
end
