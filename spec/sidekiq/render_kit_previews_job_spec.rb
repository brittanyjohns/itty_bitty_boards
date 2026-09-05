require "rails_helper"

RSpec.describe RenderKitPreviewsJob do
  let(:kit_page) { create(:kit_page) }
  let(:pdf) { file_fixture("sample.pdf").binread }

  def upload!(page = kit_page, filename: "handout.pdf", bytes: nil)
    page.attach_document!(io: StringIO.new(bytes || pdf), filename: filename)
  end

  before { allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_return(true) }

  # SAMPLE_PDF_PAGES, not the render limit: the limit is 10 and the fixture is
  # two pages, so what this pins is the clamp to the document's real length.
  SAMPLE_PDF_PAGES = 2

  it "renders every page of the first document" do
    upload!

    described_class.new.perform(kit_page.id)

    expect(kit_page.reload.preview_images.size).to eq(SAMPLE_PDF_PAGES)
    expect(kit_page.gallery_images.map { |image| image[:variant] }).to eq(%w[page_1 page_2])
  end

  # The previews are a picture OF the current download, so a page left over
  # from a document that has been removed is worse than no picture at all.
  it "replaces the previous set rather than adding to it" do
    upload!
    kit_page.attach_preview_image!(bytes: "stale", page: 1)
    kit_page.attach_preview_image!(bytes: "stale", page: 2)

    described_class.new.perform(kit_page.id)

    expect(kit_page.reload.preview_images.size).to eq(SAMPLE_PDF_PAGES)
    expect(kit_page.preview_images.map(&:download)).not_to include("stale")
  end

  it "clears the previews when the last document is gone" do
    upload!
    kit_page.attach_preview_image!(bytes: "stale", page: 1)
    kit_page.documents.each(&:purge)
    kit_page.documents.reset

    described_class.new.perform(kit_page.id)

    expect(kit_page.reload.preview_images).to be_empty
  end

  it "does nothing for a page that has been deleted" do
    id = kit_page.id
    kit_page.destroy!

    expect { described_class.new.perform(id) }.not_to raise_error
  end

  # The gate exists so a host whose libvips has no PDF loader still works.
  it "leaves the page alone when the renderer is unavailable" do
    allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_return(false)
    upload!

    expect { described_class.new.perform(kit_page.id) }.not_to raise_error
    expect(kit_page.reload.preview_images).to be_empty
  end

  it "does not raise on a document that isn't a readable PDF" do
    allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_call_original
    upload!(bytes: "%PDF but not really")

    expect { described_class.new.perform(kit_page.id) }.not_to raise_error
    expect(kit_page.reload.preview_images).to be_empty
  end

  describe "every document, not just the first" do
    # Fake pages rather than more fixtures: what's under test is that the job
    # walks all the documents and stamps what it attaches, not libvips.
    def stub_renderer!(pages: 3)
      renderer = instance_double(KitPages::DocumentPreviewRenderer)
      allow(KitPages::DocumentPreviewRenderer).to receive(:new).and_return(renderer)
      allow(renderer).to receive(:each_page) do |_bytes, &block|
        (0...pages).each { |index| block.call("PNG #{index}", index) }
      end
      renderer
    end

    it "renders the pages of every uploaded document" do
      first = upload!(filename: "handout.pdf")
      second = upload!(filename: "guide.pdf")
      stub_renderer!(pages: 3)

      described_class.new.perform(kit_page.id)

      expect(kit_page.reload.preview_images.size).to eq(6)
      expect(kit_page.preview_rows.map { |row| row[:document_id] }.uniq)
        .to eq([first.id.to_s, second.id.to_s])
    end

    it "stamps each preview with its document and the batch it belongs to" do
      document = upload!
      stub_renderer!(pages: 2)

      described_class.new.perform(kit_page.id)

      metadata = kit_page.reload.preview_images.map(&:metadata)
      expect(metadata.map { |m| m["document_id"] }).to all(eq(document.id))
      expect(metadata.map { |m| m["batch"] }.uniq.size).to eq(1)
      expect(metadata.map { |m| m["batch"] }.first).to be_present
    end

    # Purge-first blanks a live public gallery for as long as the job runs.
    it "keeps the old previews resolvable until the new set is complete" do
      upload!
      kit_page.attach_preview_image!(bytes: "stale", page: 1)
      seen_during_render = []

      renderer = stub_renderer!(pages: 2)
      allow(renderer).to receive(:each_page) do |_bytes, &block|
        block.call("PNG one", 0)
        seen_during_render = kit_page.reload.preview_rows.map { |row| row[:page] }
        block.call("PNG two", 1)
      end

      described_class.new.perform(kit_page.id)

      # Mid-render the page is still serving the previous set, not an empty one.
      expect(seen_during_render).to eq([1])
      expect(kit_page.reload.preview_images.map(&:download)).not_to include("stale")
    end

    it "honours the render limit per document" do
      upload!
      allow(KitPage).to receive(:preview_render_limit).and_return(1)

      described_class.new.perform(kit_page.id)

      expect(kit_page.reload.preview_images.size).to eq(1)
    end
  end
end
