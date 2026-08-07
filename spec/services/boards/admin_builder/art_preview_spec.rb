require "rails_helper"

RSpec.describe Boards::AdminBuilder::ArtPreview do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def image_with_doc(label:, license: nil, source_type: "OpenAI")
    image = Image.create!(label: label, user_id: admin.id)
    doc = image.docs.create!(user_id: admin.id, license: license, source_type: source_type, raw: label)
    doc.image.attach(
      io: StringIO.new(file_fixture("sample.png").read),
      filename: "#{label}.png",
      content_type: "image/png",
    )
    image
  end

  before { admin }

  # The single most important property of this service: Preview is a read-only
  # path, and Boards::ImageResolver.resolve/resolve_all create a blank Image for
  # any label with no match. A regression here silently litters the library.
  it "writes nothing, for labels with art and labels without" do
    image_with_doc(label: "apple")

    expect {
      described_class.new(labels: %w[apple nonexistentwordxyz], commercial_safe_only: false).call
    }.to not_change(Image, :count).and not_change(Doc, :count)
  end

  it "reports an exact match with its image and a display url" do
    image = image_with_doc(label: "apple")

    row = described_class.new(labels: ["apple"], commercial_safe_only: false).call[:rows].first

    expect(row.image_id).to eq(image.id)
    expect(row.matched_label).to eq("apple")
    expect(row).to be_exact
    expect(row.display_url).to be_present
  end

  it "matches case-insensitively without calling it fuzzy" do
    image_with_doc(label: "apple")

    row = described_class.new(labels: ["Apple"], commercial_safe_only: false).call[:rows].first

    expect(row).to be_found
    expect(row).to be_exact
  end

  # The classic failure: "my" resolving to art labelled with a whole sentence.
  # A hit whose own label is a different word is a judgment call, not a match.
  it "flags a hit whose own label is a different word as inexact" do
    image_with_doc(label: "applesauce")

    result = described_class.new(labels: ["apple"], commercial_safe_only: false).call

    expect(result[:rows].first).to be_found
    expect(result[:rows].first).not_to be_exact
    expect(result[:inexact]).to eq(["apple"])
  end

  it "reports a label with no art as missing" do
    result = described_class.new(labels: ["nonexistentwordxyz"], commercial_safe_only: false).call

    expect(result[:missing]).to eq(["nonexistentwordxyz"])
    expect(result[:rows].first).not_to be_found
    expect(result[:coverage_pct]).to eq(0)
  end

  it "computes coverage across the whole list" do
    image_with_doc(label: "apple")
    image_with_doc(label: "banana")

    result = described_class.new(labels: %w[apple banana nonexistentwordxyz], commercial_safe_only: false).call

    expect(result[:total]).to eq(3)
    expect(result[:found]).to eq(2)
    expect(result[:coverage_pct]).to eq(67)
  end

  it "surfaces licensing so an unsafe pick can be judged rather than hidden" do
    image_with_doc(label: "apple", license: "CC BY-NC", source_type: "OpenSymbols")

    row = described_class.new(labels: ["apple"], commercial_safe_only: true).call[:rows].first

    expect(row).to be_found
    expect(row.commercial_safe).to be(false)
  end

  it "ignores blank lines in the label list" do
    result = described_class.new(labels: ["apple", "", "  "], commercial_safe_only: false).call
    expect(result[:total]).to eq(1)
  end
end
