require "rails_helper"

RSpec.describe RenderKitPreviewsJob do
  let(:kit_page) { create(:kit_page) }
  let(:pdf) { file_fixture("sample.pdf").binread }

  def upload!(page = kit_page, filename: "handout.pdf", bytes: nil)
    page.attach_document!(io: StringIO.new(bytes || pdf), filename: filename)
  end

  before { allow(KitPages::DocumentPreviewRenderer).to receive(:available?).and_return(true) }

  it "renders the first pages of the first document" do
    upload!

    described_class.new.perform(kit_page.id)

    expect(kit_page.reload.preview_images.size).to eq(KitPage::PREVIEW_PAGE_COUNT)
    expect(kit_page.gallery_images.map { |image| image[:variant] }).to eq(%w[page_1 page_2])
  end

  # The previews are a picture OF the current download, so a page left over
  # from a document that has been removed is worse than no picture at all.
  it "replaces the previous set rather than adding to it" do
    upload!
    kit_page.attach_preview_image!(bytes: "stale", page: 1)
    kit_page.attach_preview_image!(bytes: "stale", page: 2)

    described_class.new.perform(kit_page.id)

    expect(kit_page.reload.preview_images.size).to eq(KitPage::PREVIEW_PAGE_COUNT)
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
end
