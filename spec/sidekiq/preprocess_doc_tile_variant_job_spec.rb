require "rails_helper"

RSpec.describe PreprocessDocTileVariantJob, type: :sidekiq do
  describe "#perform" do
    it "is a no-op in staging so missing-blob errors don't pile up" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      expect(Doc).not_to receive(:includes)

      described_class.new.perform(123)
    end

    it "no-ops when the doc is missing" do
      allow(AppEnv).to receive(:staging?).and_return(false)

      expect { described_class.new.perform(-1) }.not_to raise_error
    end
  end
end
