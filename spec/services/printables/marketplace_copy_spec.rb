require "rails_helper"

RSpec.describe Printables::MarketplaceCopy do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
  end

  subject(:copy) { described_class.new(printable) }

  def field(fields, label) = fields.find { |f| f.label == label }

  describe "TPT" do
    it "trims the title to TPT's 100-char cap on a word boundary, without the Etsy suffix" do
      long = "Snack Time " * 12
      printable.update!(listing_copy: {
        "title" => "#{long}(Digital Download)", "description" => "D", "tags" => [], "price_cents" => 500,
      })

      value = field(copy.tpt_fields, "Product title").value

      expect(value.length).to be <= described_class::TPT_TITLE_MAX
      expect(value).not_to include("Digital Download")
      expect(value).not_to end_with("Sna")
    end

    it "lays out every field TPT's upload form asks for" do
      labels = copy.tpt_fields.map(&:label)

      expect(labels).to include(
        "Product title", "Description", "Price (USD)", "Grade levels",
        "Subjects", "Resource types", "Number of pages", "Search keywords",
        "Files to upload", "Standards",
      )
    end

    it "trims the keyword list — TPT takes a handful, not Etsy's thirteen" do
      value = field(copy.tpt_fields, "Search keywords").value
      expect(value.split(",").length).to eq(described_class::TPT_KEYWORD_COUNT)
    end

    it "lists the PDFs by name so there's no guessing which files to upload" do
      printable.attach_pdf!(filename: "core-words.pdf", bytes: "b", variant: BoardPrintable::VARIANT_FULL)

      expect(field(described_class.new(printable.reload).tpt_fields, "Files to upload").value)
        .to eq("core-words.pdf")
    end
  end

  describe "generic" do
    it "hands back the title, description, tags and price unchanged" do
      printable.update!(listing_copy: {
        "title" => "T", "description" => "D", "tags" => %w[aac printable], "price_cents" => 450,
      })

      fields = described_class.new(printable.reload).generic_fields

      expect(field(fields, "Title").value).to eq("T")
      expect(field(fields, "Tags").value).to eq("aac, printable")
      expect(field(fields, "Price (USD)").value).to eq("4.50")
    end
  end

  it "falls back to the generated defaults when nothing has been saved yet" do
    expect(copy.title).to be_present
    expect(copy.tags).to be_present
  end
end
