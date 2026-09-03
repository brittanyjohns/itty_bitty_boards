# frozen_string_literal: true

require "rails_helper"

# The fallback a public page offers when the owner has starred no boards of
# their own. It used to be the whole `Board.public_boards` library, unordered
# and uncapped — ~75 cards on the page a parent hands to a teacher.
RSpec.describe Board, ".public_starter_boards" do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def public_board(name:, slug: nil, tags: [], category: nil)
    create(
      :board,
      user: admin,
      name: name,
      slug: slug || name.parameterize,
      tags: tags,
      category: category,
      predefined: true,
      published: true,
      parent_type: "User",
    )
  end

  def starter_names = described_class.public_starter_boards.map(&:name)

  it "leads with the seeded MySpeak starters in their curated order" do
    # Created in a deliberately unhelpful order — nothing here is alphabetical.
    public_board(name: "School Day", slug: "myspeak-school", tags: ["myspeak"])
    public_board(name: "Basic Needs", slug: "myspeak-basics", tags: ["myspeak"])
    public_board(name: "Food & Drink", slug: "myspeak-food", tags: ["myspeak"])
    public_board(name: "Feelings", slug: "myspeak-feelings", tags: ["myspeak"])
    public_board(name: "Out & About", slug: "myspeak-social", tags: ["myspeak"])

    expect(starter_names).to eq(
      ["Basic Needs", "Feelings", "Out & About", "Food & Drink", "School Day"]
    )
  end

  it "caps the list rather than serving the whole library" do
    public_board(name: "Basic Needs", slug: "myspeak-basics", tags: ["myspeak"])
    12.times { |n| public_board(name: "Filler #{n}") }

    boards = described_class.public_starter_boards
    expect(boards.size).to eq(described_class.public_starter_limit)
    expect(boards.first.name).to eq("Basic Needs")
  end

  it "keeps one board per name, however it was punctuated or cased" do
    public_board(name: "Lunch and Snack", slug: "lunch-and-snack-1")
    public_board(name: "lunch & snack", slug: "lunch-and-snack-2")
    public_board(name: "numbers", slug: "numbers-1")
    public_board(name: "Numbers", slug: "numbers-2")

    expect(starter_names.size).to eq(2)
    expect(starter_names.map { |n| Board.normalized_board_name(n) })
      .to contain_exactly("lunch and snack", "numbers")
  end

  # Two boards that merely spell the same idea differently are still two
  # boards — collapsing them would hide something an admin curated. The cap is
  # what keeps them off the page; `rake public_boards:dedupe` is what retires
  # the real duplicates.
  it "does not collapse differently-worded boards" do
    public_board(name: "Letters, Colors, Numbers", slug: "lcn-1")
    public_board(name: "Letters-Numbers-Colors", slug: "lnc-2")

    expect(starter_names.size).to eq(2)
  end

  # Degradation path: an environment that has never run the starter seed must
  # still get a short list, not an empty page and not the whole library.
  describe "with no myspeak-tagged boards" do
    it "prefers the welcome category, then falls back alphabetically" do
      public_board(name: "Zebra Words", category: "welcome")
      public_board(name: "At the Hair Salon")
      public_board(name: "McDonalds")

      expect(starter_names.first).to eq("Zebra Words")
      expect(starter_names).to eq(["Zebra Words", "At the Hair Salon", "McDonalds"])
    end
  end

  it "excludes boards that aren't in the public library" do
    public_board(name: "Basic Needs", slug: "myspeak-basics", tags: ["myspeak"])
    create(:board, user: create(:user), name: "Someone's Board", published: true, predefined: false)
    create(:board, user: admin, name: "Unpublished", published: false, predefined: true, parent_type: "User")

    expect(starter_names).to eq(["Basic Needs"])
  end

  describe ".public_starter_limit" do
    it "is ENV-tunable" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PUBLIC_STARTER_BOARD_LIMIT", anything).and_return("2")

      3.times { |n| public_board(name: "Board #{n}") }
      expect(described_class.public_starter_boards.size).to eq(2)
    end
  end
end
