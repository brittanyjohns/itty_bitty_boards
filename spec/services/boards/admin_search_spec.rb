require "rails_helper"

RSpec.describe Boards::AdminSearch do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  # board_type defaults to nil on the factory, and the app's `non_menus`
  # scope (`where.not(board_type: "menu")`) follows normal SQL NULL
  # semantics: a NULL board_type is excluded, not treated as "not menu".
  # Default it to a real non-menu type here so these boards land in
  # main_boards like a real created board would; tests that need "menu"
  # still override it via **attrs.
  def admin_board(name:, description: nil, tags: [], published: false, **attrs)
    attrs[:board_type] ||= "board"
    create(:board, user: admin, name: name, description: description,
                   tags: tags, published: published, sub_board: false, **attrs)
  end

  before { admin }

  describe "scope" do
    it "returns admin-owned top-level boards" do
      board = admin_board(name: "Animals")
      expect(described_class.new.call).to include(board)
    end

    it "excludes boards owned by another user" do
      other = create(:user)
      board = create(:board, user: other, name: "Animals", sub_board: false)
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes sub-boards" do
      # Board#check_is_sub_board (before_save) recomputes sub_board from real
      # parent-board linkage, so passing sub_board: true on create doesn't
      # stick. Force the column directly to test AdminSearch's own
      # filtering rather than reconstructing a real parent/child board tree.
      board = admin_board(name: "Sub")
      board.update_column(:sub_board, true)
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes menus" do
      board = admin_board(name: "Menu board", board_type: "menu")
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes builder children" do
      board = admin_board(name: "Builder child", settings: { "builder_child" => true })
      expect(described_class.new.call).not_to include(board)
    end
  end

  describe "q matching" do
    it "matches on a name prefix" do
      board = admin_board(name: "Animals")
      expect(described_class.new(q: "anim").call).to include(board)
    end

    it "matches on a description substring" do
      board = admin_board(name: "Zoo", description: "all about animals here")
      expect(described_class.new(q: "animals").call).to include(board)
    end

    it "returns nothing when neither field matches" do
      admin_board(name: "Animals")
      expect(described_class.new(q: "spaceship").call).to be_empty
    end
  end

  describe "published filter" do
    it "returns both published and unpublished when unset" do
      published = admin_board(name: "Published one", published: true)
      draft = admin_board(name: "Draft one", published: false)
      results = described_class.new.call
      expect(results).to include(published, draft)
    end

    it "returns only published when published: true" do
      published = admin_board(name: "Published two", published: true)
      draft = admin_board(name: "Draft two", published: false)
      results = described_class.new(published: true).call
      expect(results).to include(published)
      expect(results).not_to include(draft)
    end

    it "returns only unpublished when published: false" do
      published = admin_board(name: "Published three", published: true)
      draft = admin_board(name: "Draft three", published: false)
      results = described_class.new(published: false).call
      expect(results).to include(draft)
      expect(results).not_to include(published)
    end
  end

  describe "tag filtering" do
    it "requires ALL tags by default" do
      both = admin_board(name: "Both", tags: ["printable", "core"])
      one = admin_board(name: "One", tags: ["printable"])
      results = described_class.new(tags: "printable,core").call
      expect(results).to include(both)
      expect(results).not_to include(one)
    end

    it "requires ANY tag when tag_match is any" do
      one = admin_board(name: "One any", tags: ["printable"])
      expect(described_class.new(tags: "printable,core", tag_match: "any").call).to include(one)
    end

    it "normalizes tag values" do
      board = admin_board(name: "Normalized", tags: ["printable"])
      expect(described_class.new(tags: "  Printable  ").call).to include(board)
    end

    it "ANDs tags with q" do
      match = admin_board(name: "Animals", tags: ["printable"])
      wrong_tag = admin_board(name: "Animals two", tags: ["other"])
      results = described_class.new(q: "anim", tags: "printable").call
      expect(results).to include(match)
      expect(results).not_to include(wrong_tag)
    end
  end

  describe "limit" do
    it "clamps to MAX_LIMIT" do
      expect(described_class.new(limit: 9_999).limit).to eq(described_class::MAX_LIMIT)
    end
  end

  describe ".tag_counts" do
    it "counts tags across admin boards" do
      admin_board(name: "A", tags: ["printable", "core"])
      admin_board(name: "B", tags: ["printable"])

      counts = described_class.tag_counts
      expect(counts.find { |c| c[:tag] == "printable" }[:count]).to eq(2)
      expect(counts.find { |c| c[:tag] == "core" }[:count]).to eq(1)
    end

    it "includes tags that appear only on unpublished boards" do
      admin_board(name: "Draft tagged", tags: ["draftonly"], published: false)
      expect(described_class.tag_counts.map { |c| c[:tag] }).to include("draftonly")
    end

    it "respects the published filter" do
      admin_board(name: "Draft tagged two", tags: ["draftonly2"], published: false)
      expect(described_class.tag_counts(published: true).map { |c| c[:tag] })
        .not_to include("draftonly2")
    end

    it "orders by count descending" do
      admin_board(name: "C", tags: ["common", "rare"])
      admin_board(name: "D", tags: ["common"])
      counts = described_class.tag_counts
      expect(counts.first[:tag]).to eq("common")
    end
  end
end
