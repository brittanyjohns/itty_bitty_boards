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
    it "attaches one fully-wrapped 6-page file" do
      printable = printable_for

      described_class.new(printable: printable).call
      printable.reload

      expect(printable.status).to eq("complete")
      expect(printable.files.count).to eq(1)
      # cover, how-to-use, colour, low-ink, license, credits
      expect(printable.page_count).to eq(6)
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

    it "attaches exactly two files, colour and low-ink, each fully wrapped" do
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call
      printable.reload

      expect(printable.status).to eq("complete")
      files = printable.files_view.sort_by { |f| f[:variant] }
      expect(files.map { |f| f[:variant] })
        .to eq([BoardPrintable::VARIANT_COLOR, BoardPrintable::VARIANT_LOW_INK])
      expect(files.map { |f| f[:filename] })
        .to eq(["core-words.color.pdf", "core-words.low-ink.pdf"])

      # 2N + 8: each file is cover + how-to-use + 3 board pages + license + credits.
      expect(printable.page_count).to eq(14)
      expect(printable.board_ids).to eq([root.id, child_a.id, child_b.id])
    end

    it "points every board page's QR at its own board, and the cover's at the root" do
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call

      # Two renders per board (colour + low-ink), each targeting that board by
      # its slug — CollectPages.qr_key_for, matching Board#public_url.
      [root, child_a, child_b].each do |board|
        key = board.slug.presence || board.id
        expect(qr_targets.count("https://app.speakanyway.com/pb/#{key}")).to eq(2)
      end
      expect(qr_targets.length).to eq(6)
    end

    # Each board in a tree gets its own key, so a slugless board in the middle
    # can't quietly take the root's URL.
    it "keys each board page separately when one board has no slug" do
      child_a.update_column(:slug, "")
      printable = printable_for(include_subboards: true)

      described_class.new(printable: printable).call

      expect(qr_targets.uniq.length).to eq(3)
      expect(qr_targets.count("https://app.speakanyway.com/pb/#{child_a.id}")).to eq(2)
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

  # The deterministic storage key is scoped by record id, so this only has to
  # survive a re-run of the SAME record — which is what a Sidekiq retry does.
  it "can regenerate the same record without colliding on the blob key" do
    printable = printable_for

    described_class.new(printable: printable).call
    expect { described_class.new(printable: printable).call }.not_to raise_error

    expect(printable.reload.files.count).to eq(1)
  end
end
