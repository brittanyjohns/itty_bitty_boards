require "rails_helper"

# Every wrapper and board page here is a real one-page PDF given a distinctive
# MediaBox width. That width is the page's fingerprint: after the merge, reading
# widths off the result says exactly which source landed where, which is the
# only thing this service decides.
RSpec.describe Boards::Printables::MergePdf do
  def page_pdf(width)
    pdf = CombinePDF.new
    pdf << CombinePDF.create_page([0, 0, width, 792])
    pdf.to_pdf
  end

  let(:cover) { 601 }
  let(:how_to) { 602 }
  let(:license) { 603 }
  let(:credits) { 604 }
  let(:cover_low_ink) { 605 }
  let(:how_to_low_ink) { 606 }
  let(:how_to_trim_ready) { 607 }

  let(:wrappers) do
    {
      cover: page_pdf(cover),
      how_to_use: page_pdf(how_to),
      license: page_pdf(license),
      credits: page_pdf(credits),
      cover_low_ink: page_pdf(cover_low_ink),
      how_to_use_low_ink: page_pdf(how_to_low_ink),
      how_to_use_trim_ready: page_pdf(how_to_trim_ready),
    }
  end

  def board_page(variant, width)
    Boards::Printables::CollectPages::Page.new(
      pdf_bytes: page_pdf(width),
      board_id: width,
      board_name: "Board #{width}",
      variant: variant,
    )
  end

  def widths(file)
    CombinePDF.parse(file.bytes).pages.map { |page| page[:MediaBox][2] }
  end

  describe "a subboard bundle" do
    let(:boards) { [double(id: 1), double(id: 2)] }

    let(:pages) do
      [
        board_page(BoardPrintable::VARIANT_COLOR, 101),
        board_page(BoardPrintable::VARIANT_COLOR, 102),
        board_page(BoardPrintable::VARIANT_LOW_INK, 201),
        board_page(BoardPrintable::VARIANT_LOW_INK, 202),
        board_page(BoardPrintable::VARIANT_TRIM_READY, 301),
        board_page(BoardPrintable::VARIANT_TRIM_READY, 302),
      ]
    end

    subject(:files) do
      described_class.new(wrappers: wrappers, pages: pages, boards: boards, slug: "core-words").call
    end

    it "gives the low-ink file its own cover and instructions" do
      low_ink = files.find { |f| f.variant == BoardPrintable::VARIANT_LOW_INK }

      expect(widths(low_ink)).to eq([cover_low_ink, how_to_low_ink, 201, 202, license, credits])
    end

    it "gives the colour file the colour cover and instructions" do
      colour = files.find { |f| f.variant == BoardPrintable::VARIANT_COLOR }

      expect(widths(colour)).to eq([cover, how_to, 101, 102, license, credits])
    end

    # The trim-ready file is full colour, so it keeps the colour cover — only
    # its board pages and its instructions differ.
    it "gives the trim-ready file the colour cover and its own instructions" do
      trim_ready = files.find { |f| f.variant == BoardPrintable::VARIANT_TRIM_READY }

      expect(trim_ready.filename).to eq("core-words.trim-ready.pdf")
      expect(widths(trim_ready)).to eq([cover, how_to_trim_ready, 301, 302, license, credits])
    end

    # The three files have to stay interchangeable — same length, same
    # structure, only the pages differ.
    it "gives every file the same page count" do
      expect(files.map(&:page_count).uniq).to eq([6])
    end

    it "emits one file per download variant, colour first" do
      expect(files.map(&:variant)).to eq(BoardPrintable::DOWNLOAD_VARIANTS)
    end

    # RenderWrappers only produces an ink-light cover for a set, but MergePdf
    # must not assume the key is present — a missing one falls back rather than
    # merging nil and blowing up mid-job.
    it "falls back to the colour pages when no per-variant wrappers were rendered" do
      wrappers.delete(:cover_low_ink)
      wrappers.delete(:how_to_use_low_ink)
      wrappers.delete(:how_to_use_trim_ready)

      %w[low_ink trim_ready].each do |variant|
        file = files.find { |f| f.variant == variant }

        expect(widths(file).take(2)).to eq([cover, how_to])
      end
    end
  end

  # One document holding every variant: there is no low-ink or trim-ready FILE
  # to give its own identity to, so it keeps the one colour cover.
  describe "a single board" do
    it "wraps every variant in one file behind the colour cover and instructions" do
      pages = [
        board_page(BoardPrintable::VARIANT_COLOR, 101),
        board_page(BoardPrintable::VARIANT_LOW_INK, 201),
        board_page(BoardPrintable::VARIANT_TRIM_READY, 301),
      ]

      files = described_class.new(
        wrappers: wrappers, pages: pages, boards: [double(id: 1)], slug: "core-words"
      ).call

      expect(files.length).to eq(1)
      expect(files.first.variant).to eq(BoardPrintable::VARIANT_FULL)
      expect(files.first.filename).to eq("core-words.pdf")
      expect(widths(files.first)).to eq([cover, how_to, 101, 201, 301, license, credits])
    end
  end
end
