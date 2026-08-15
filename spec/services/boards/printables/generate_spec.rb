require "rails_helper"

RSpec.describe Boards::Printables::Generate do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, name: "Core Words", slug: "core-words") }

  # A real one-page PDF, so the merge runs for real and page counts mean
  # something. Grover's "%PDF-fake" stub can't be parsed by combine_pdf.
  let(:one_page_pdf) do
    pdf = CombinePDF.new
    pdf << CombinePDF.create_page
    pdf.to_pdf
  end

  let(:qr_targets) { [] }

  before do
    # Bypass Chromium entirely; every render returns the same blank page.
    allow(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: one_page_pdf))
    # Bypass the heavy ERB renders — this service's template responsibility is
    # just feeding assigns in, which the view specs would cover separately.
    allow(ApplicationController).to receive(:render).and_return("<html></html>")

    # RenderAssetData still runs for real, so the QR targeting is genuinely
    # exercised rather than asserted against a stub.
    allow(Boards::RenderAssetData).to receive(:new).and_wrap_original do |original, **kwargs|
      qr_targets << kwargs[:qr_target_url]
      original.call(**kwargs)
    end
  end

  def link(from, to, position: 0)
    create(:board_image, board: from, predictive_board_id: to.id, position: position)
  end

  def printable_for(**attrs)
    BoardPrintable.create!(board: root, created_by: user, **attrs)
  end

  describe "a single board" do
    it "attaches one fully-wrapped 7-page file" do
      printable = printable_for

      described_class.new(printable: printable).call
      printable.reload

      expect(printable.status).to eq("complete")
      expect(printable.files.count).to eq(1)
      # cover, how-to-use, colour, low-ink, trim-ready, license, credits
      expect(printable.page_count).to eq(7)
      expect(printable.board_ids).to eq([root.id])
      expect(printable.error_message).to be_nil
    end

    it "names the file from the board slug and marks it as the whole printable" do
      printable = printable_for

      described_class.new(printable: printable).call

      file = printable.reload.files_view.first
      expect(file[:filename]).to eq("core-words.pdf")
      expect(file[:variant]).to eq(BoardPrintable::VARIANT_FULL)
    end

    it "falls back to the board id when the board has no slug" do
      root.update_column(:slug, nil)
      printable = printable_for

      described_class.new(printable: printable).call

      expect(printable.reload.files_view.first[:filename]).to eq("board-#{root.id}.pdf")
    end
  end

  describe "a subboard bundle" do
    let!(:child_a) { create(:board, user: user, name: "Food") }
    let!(:child_b) { create(:board, user: user, name: "Play") }

    before do
      link(root, child_a, position: 0)
      link(root, child_b, position: 1)
    end

    it "attaches one file per download variant, each fully wrapped" do
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call
      printable.reload

      expect(printable.status).to eq("complete")
      files = printable.files_view
      expect(files.map { |f| f[:variant] }).to eq(BoardPrintable::DOWNLOAD_VARIANTS)
      expect(files.map { |f| f[:filename] })
        .to eq(["core-words.color.pdf", "core-words.low-ink.pdf", "core-words.trim-ready.pdf"])

      # 3 x (cover + how-to-use + 3 board pages + license + credits).
      expect(printable.page_count).to eq(21)
      expect(printable.board_ids).to eq([root.id, child_a.id, child_b.id])
    end

    it "points every board page's QR at its own board, and the cover's at the root" do
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call

      # One render per board per download variant, each targeting that board by
      # its slug — CollectPages.qr_key_for, matching Board#public_url. The
      # trim-ready page is included: it drops the header band but keeps a QR.
      variants = BoardPrintable::DOWNLOAD_VARIANTS.length
      [root, child_a, child_b].each do |board|
        key = board.slug.presence || board.id
        expect(qr_targets.count("https://app.speakanyway.com/pb/#{key}")).to eq(variants)
      end
      expect(qr_targets.length).to eq(3 * variants)
    end

    # Each board in a tree gets its own key, so a slugless board in the middle
    # can't quietly take the root's URL.
    it "keys each board page separately when one board has no slug" do
      child_a.update_column(:slug, "")
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call

      expect(qr_targets.uniq.length).to eq(3)
      expect(qr_targets.count("https://app.speakanyway.com/pb/#{child_a.id}"))
        .to eq(BoardPrintable::DOWNLOAD_VARIANTS.length)
    end
  end

  describe "when generation fails" do
    it "records the failure and re-raises so Sidekiq retries" do
      allow(Grover).to receive(:new).and_raise(StandardError, "Chrome crashed")
      printable = printable_for

      expect { described_class.new(printable: printable).call }
        .to raise_error(StandardError, "Chrome crashed")

      printable.reload
      expect(printable.status).to eq("failed")
      expect(printable.error_message).to eq("Chrome crashed")
      expect(printable.files).not_to be_attached
    end
  end

  # The storage key is scoped by record id and versioned per run, so this has to
  # survive a re-run of the SAME record — which is what a Sidekiq retry does.
  it "can regenerate the same record without colliding on the blob key" do
    printable = printable_for

    described_class.new(printable: printable).call
    expect { described_class.new(printable: printable).call }.not_to raise_error

    expect(printable.reload.files.count).to eq(1)
  end

  # The bug this guards: production serves these off CloudFront as CDN_HOST +
  # the blob key, and CloudFront caches by path — so re-running onto the same
  # key left "Regenerate" downloading the PREVIOUS document, with none of the
  # board edits that motivated the re-run.
  it "gives a regenerated PDF a new storage key so a CDN can't serve the old one" do
    printable = printable_for

    described_class.new(printable: printable).call
    first_key = printable.reload.pdf_files.first.key

    described_class.new(printable: printable).call
    second = printable.reload.pdf_files.first

    expect(second.key).not_to eq(first_key)
    # Same product, same download name — only the cached path moved.
    expect(second.filename.to_s).to eq("core-words.pdf")
    expect(second.key).to start_with("board_printables/#{printable.id}/")
    expect(second.key).to end_with("/core-words.pdf")
  end

  it "leaves exactly one downloadable file per variant after a regenerate" do
    printable = printable_for(include_subboards: true)
    link(root, create(:board, user: user, name: "Food"))

    described_class.new(printable: printable).call
    described_class.new(printable: printable).call

    expect(printable.reload.files_view.map { |f| f[:variant] })
      .to eq(BoardPrintable::DOWNLOAD_VARIANTS)
  end

  # The admin "Regenerate" action re-runs this on a record that already has
  # files. The filename carries the board slug, so a rename would otherwise
  # leave the previous PDF attached and downloadable next to the fresh one.
  it "purges a previous run's PDF when the board slug has changed" do
    printable = printable_for
    described_class.new(printable: printable).call

    root.update_column(:slug, "core-words-v2")
    described_class.new(printable: printable).call
    printable.reload

    expect(printable.files_view.map { |f| f[:filename] }).to eq(["core-words-v2.pdf"])
  end

  # A subboard added since the first run flips the document from one full file
  # to a file per variant; the orphaned "full" file is not a real download.
  it "purges the single-board file when the tree has grown into a bundle" do
    printable = printable_for(include_subboards: true)
    described_class.new(printable: printable).call

    link(root, create(:board, user: user, name: "Food"))
    described_class.new(printable: printable).call
    printable.reload

    expect(printable.files_view.map { |f| f[:variant] })
      .to match_array(BoardPrintable::DOWNLOAD_VARIANTS)
  end

  it "leaves the listing images alone when the PDFs are regenerated" do
    printable = printable_for
    described_class.new(printable: printable).call
    printable.attach_image!(bytes: "png", variant: BoardPrintable::IMAGE_HERO)

    described_class.new(printable: printable).call

    expect(printable.reload.image_files.map { |f| f.metadata["variant"] }).to eq([BoardPrintable::IMAGE_HERO])
  end
end
