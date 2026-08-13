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

  def pages_for(labels, children: [])
    Boards::AdminBuilder::Plan.pages(
      root: { name: "Board", columns: 2, tile_count: 4, tiles: labels.map { |label| { label: label } } },
      children: children,
    )
  end

  before { admin }

  # The single most important property of this service: Preview is a read-only
  # path, and Boards::ImageResolver.resolve/resolve_all create a blank Image for
  # any label with no match. A regression here silently litters the library.
  it "writes nothing, for labels with art and labels without" do
    image_with_doc(label: "apple")

    expect {
      described_class.new(pages: pages_for(%w[apple nonexistentwordxyz]), commercial_safe_only: false).call
    }.to not_change(Image, :count).and not_change(Doc, :count)
  end

  it "reports an exact match with its image and a display url" do
    image = image_with_doc(label: "apple")

    row = described_class.new(pages: pages_for(["apple"]), commercial_safe_only: false).call[:pages].first[:rows].first

    expect(row.image_id).to eq(image.id)
    expect(row.matched_label).to eq("apple")
    expect(row).to be_exact
    expect(row.display_url).to be_present
  end

  it "matches case-insensitively without calling it fuzzy" do
    image_with_doc(label: "apple")

    row = described_class.new(pages: pages_for(["Apple"]), commercial_safe_only: false).call[:pages].first[:rows].first

    expect(row).to be_found
    expect(row).to be_exact
  end

  # The classic failure: "my" resolving to art labelled with a whole sentence.
  # A hit whose own label is a different word is a judgment call, not a match.
  it "flags a hit whose own label is a different word as inexact" do
    image_with_doc(label: "applesauce")

    result = described_class.new(pages: pages_for(["apple"]), commercial_safe_only: false).call

    expect(result[:pages].first[:rows].first).to be_found
    expect(result[:pages].first[:rows].first).not_to be_exact
    expect(result[:inexact]).to eq(["apple"])
  end

  it "reports a label with no art as missing" do
    result = described_class.new(pages: pages_for(["nonexistentwordxyz"]), commercial_safe_only: false).call

    expect(result[:missing]).to eq(["nonexistentwordxyz"])
    expect(result[:pages].first[:rows].first).not_to be_found
    expect(result[:coverage_pct]).to eq(0)
  end

  it "computes coverage across the whole list" do
    image_with_doc(label: "apple")
    image_with_doc(label: "banana")

    result = described_class.new(pages: pages_for(%w[apple banana nonexistentwordxyz]), commercial_safe_only: false).call

    expect(result[:total]).to eq(3)
    expect(result[:found]).to eq(2)
    expect(result[:coverage_pct]).to eq(67)
  end

  it "surfaces licensing so an unsafe pick can be judged rather than hidden" do
    image_with_doc(label: "apple", license: "CC BY-NC", source_type: "OpenSymbols")

    row = described_class.new(pages: pages_for(["apple"]), commercial_safe_only: true).call[:pages].first[:rows].first

    expect(row).to be_found
    expect(row.commercial_safe).to be(false)
  end

  describe "across a set" do
    def multi_page
      pages_for(
        %w[i want more Food],
        children: [{ key: "food", name: "Food", tiles: %w[apple banana hungry more].map { |l| { label: l } } }],
      )
    end

    it "reports each page's tiles separately, in order" do
      result = described_class.new(pages: multi_page, commercial_safe_only: false).call

      expect(result[:pages].map { |page| page[:key] }).to eq([Boards::AdminBuilder::Plan::ROOT_KEY, "food"])
      expect(result[:pages].last[:name]).to eq("Food")
      expect(result[:pages].last[:rows].map(&:label)).to eq(%w[apple banana hungry more])
    end

    # The same word on two pages is one symbol and one generation — counting it
    # twice would misreport both the coverage and the AI spend.
    it "counts a label shared between pages once" do
      result = described_class.new(pages: multi_page, commercial_safe_only: false).call

      expect(result[:total]).to eq(7)
      expect(result[:missing].count("more")).to eq(1)
    end

    it "searches a repeated label only once" do
      expect_any_instance_of(Images::LabelSearch).to receive(:call).exactly(7).times.and_return([])

      described_class.new(pages: multi_page, commercial_safe_only: false).call
    end

    it "marks a tile that opens a page" do
      result = described_class.new(pages: multi_page, commercial_safe_only: false).call
      root_rows = result[:pages].first[:rows]

      expect(root_rows.last).not_to be_folder
      expect(root_rows.map(&:links_to)).to eq([nil, nil, nil, nil])
    end

    # The review grid is drawn from these, not from the form's top-level
    # columns — with mixed grids a page needn't match the main board.
    it "carries each page's own grid through" do
      pages = pages_for(
        %w[i want more Food],
        children: [{ key: "food", name: "Food", columns: 3, tile_count: 3, tiles: %w[apple banana more].map { |l| { label: l } } }],
      )

      result = described_class.new(pages: pages, commercial_safe_only: false).call

      expect(result[:pages].first).to include(columns: 2, tile_count: 4)
      expect(result[:pages].last).to include(columns: 3, tile_count: 3)
    end

    it "carries links_to through to the row" do
      pages = pages_for(%w[i want more], children: [])
      pages.first[:tiles] << { label: "Food", links_to: "food" }

      row = described_class.new(pages: pages, commercial_safe_only: false).call[:pages].first[:rows].last
      expect(row).to be_folder
      expect(row.links_to).to eq("food")
    end
  end

  # The review screen draws a real grid, and Build swaps each page's back tile
  # into its parent folder tile's cell. Previewing the authored order would show
  # the admin a layout the build isn't going to produce.
  it "draws a child page in grid order, with the back tile where its folder tile sits" do
    pages = Boards::AdminBuilder::Plan.pages(
      root: {
        name: "Board", columns: 4, tile_count: 4,
        tiles: [{ label: "i" }, { label: "Food", links_to: "food" }, { label: "want" }, { label: "more" }],
      },
      children: [{
        key: "food", name: "Food",
        tiles: [
          { label: "apple" }, { label: "banana" }, { label: "hungry" },
          { label: "back", links_to: Boards::AdminBuilder::Plan::ROOT_KEY },
        ],
      }],
    )

    result = described_class.new(pages: pages, commercial_safe_only: false).call

    expect(result[:pages].last[:rows].map(&:label)).to eq(%w[apple back hungry banana])
    # The root is never rearranged.
    expect(result[:pages].first[:rows].map(&:label)).to eq(%w[i Food want more])
  end

  it "ignores blank lines in the label list" do
    result = described_class.new(pages: pages_for(["apple", "", "  "]), commercial_safe_only: false).call
    expect(result[:total]).to eq(2)
    expect(result[:pages].first[:rows].size).to eq(3)
  end
  # The review screen lets an admin pin a different picture without asking the
  # AI for a new one, so the row has to carry the other library candidates —
  # and its own doc, so "the library's pick" is nameable.
  describe "alternatives" do
    it "offers every library candidate for the label, its own pick first" do
      first = image_with_doc(label: "apple")
      second = image_with_doc(label: "apple")

      row = described_class.new(pages: pages_for(["apple"]), commercial_safe_only: false).call[:pages].first[:rows].first

      expect(row.alternatives.map(&:image_id)).to contain_exactly(first.id, second.id)
      expect(row.alternatives.first.image_id).to eq(row.image_id)
      expect(row.alternatives.first.doc_id).to eq(row.doc_id)
      expect(row.alternatives.map(&:url)).to all(be_present)
    end

    it "is empty for a label with no art at all" do
      row = described_class.new(pages: pages_for(["nonexistentwordxyz"]), commercial_safe_only: false).call[:pages].first[:rows].first

      expect(row).not_to be_found
      expect(row.alternatives).to be_empty
    end

    # Same rule as everything else on this screen: reading the alternatives
    # must not create anything.
    it "writes nothing while collecting them" do
      image_with_doc(label: "apple")
      image_with_doc(label: "apple")

      expect {
        described_class.new(pages: pages_for(%w[apple]), commercial_safe_only: false).call
      }.to not_change(Image, :count).and not_change(Doc, :count)
    end
  end
end
