require "rails_helper"

RSpec.describe KitPages::DocumentPreviewRenderer do
  # A real 2-page PDF, not a "%PDF" stub — the whole job of this class is
  # decoding one, so stub bytes would prove nothing.
  let(:pdf) { file_fixture("sample.pdf").binread }

  before { described_class.reset_availability! }
  after { described_class.reset_availability! }

  describe ".available?" do
    it "is true when libvips can load a PDF" do
      # Skipped rather than failed where libvips was built without poppler:
      # the point of the gate is that the app still works there.
      skip "libvips has no PDF loader on this host" unless Vips.type_find("VipsOperation", "pdfload_buffer") != 0

      expect(described_class.available?).to be(true)
    end

    it "is false, and does not raise, when libvips can't answer" do
      allow(Vips).to receive(:type_find).and_raise(StandardError, "boom")

      expect(described_class.available?).to be(false)
    end
  end

  describe "#call" do
    before { skip "libvips has no PDF loader on this host" unless described_class.available? }

    it "renders the first pages as PNGs" do
      pages = described_class.new(pages: 2).call(pdf)

      expect(pages.size).to eq(2)
      expect(pages).to all(start_with("\x89PNG".b))
    end

    it "never renders more pages than the document has" do
      expect(described_class.new(pages: 5).call(pdf).size).to eq(2)
    end

    it "renders nothing when asked for no pages" do
      expect(described_class.new(pages: 0).call(pdf)).to eq([])
    end

    # Failing soft is the contract: a page with no mockups is worse, a page
    # that 500s on upload is broken.
    it "returns [] for bytes that aren't a PDF" do
      expect(described_class.new.call("not a pdf at all")).to eq([])
    end

    it "returns [] for blank bytes" do
      expect(described_class.new.call(nil)).to eq([])
      expect(described_class.new.call("")).to eq([])
    end

    it "returns [] rather than raising when a single page fails to render" do
      allow(Vips::Image).to receive(:pdfload_buffer).and_call_original
      allow(Vips::Image).to receive(:pdfload_buffer)
        .with(anything, hash_including(:page)).and_raise(Vips::Error, "bad page")

      expect(described_class.new.call(pdf)).to eq([])
    end
  end

  it "renders nothing at all when the loader is unavailable" do
    allow(described_class).to receive(:available?).and_return(false)

    expect(described_class.new.call(pdf)).to eq([])
  end
end
