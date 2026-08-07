require "rails_helper"

# The BFS walk is the piece most likely to regress and the cheapest to test in
# isolation — no rendering, no Chrome, just ids.
RSpec.describe Boards::Printables::CollectPages, ".walk_board_tree" do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, name: "Root") }

  def link(from, to, position: 0)
    create(:board_image, board: from, predictive_board_id: to.id, position: position)
  end

  def walk(board: root, include_subboards: true, max_boards: 25)
    described_class.walk_board_tree(
      board: board,
      include_subboards: include_subboards,
      max_boards: max_boards,
    ).map(&:id)
  end

  it "returns only the root when subboards are off, however many are linked" do
    link(root, create(:board, user: user))

    expect(walk(include_subboards: false)).to eq([root.id])
  end

  it "walks breadth-first with the root first" do
    a = create(:board, user: user, name: "A")
    b = create(:board, user: user, name: "B")
    c = create(:board, user: user, name: "C")
    link(root, a, position: 0)
    link(root, b, position: 1)
    link(a, c)

    # Breadth-first: both of the root's children come before A's child.
    expect(walk).to eq([root.id, a.id, b.id, c.id])
  end

  it "visits a board linked from two places only once" do
    a = create(:board, user: user)
    b = create(:board, user: user)
    shared = create(:board, user: user)
    link(root, a, position: 0)
    link(root, b, position: 1)
    link(a, shared)
    link(b, shared)

    expect(walk).to eq([root.id, a.id, b.id, shared.id])
  end

  it "terminates when a child links back to the root" do
    a = create(:board, user: user)
    link(root, a)
    link(a, root)

    expect(walk).to eq([root.id, a.id])
  end

  it "ignores a tile that links a board to itself" do
    link(root, root)

    expect(walk).to eq([root.id])
  end

  it "skips a link whose target board no longer exists" do
    a = create(:board, user: user)
    link(root, a, position: 0)
    create(:board_image, board: root, predictive_board_id: 999_999_999, position: 1)

    expect(walk).to eq([root.id, a.id])
  end

  it "ignores tiles with no predictive link" do
    create(:board_image, board: root)

    expect(walk).to eq([root.id])
  end

  # The pipeline throws rather than truncating; silently dropping boards would
  # ship an incomplete product that looks complete.
  it "raises rather than truncating when the tree exceeds max_boards" do
    3.times { |i| link(root, create(:board, user: user), position: i) }

    expect { walk(max_boards: 3) }.to raise_error(
      described_class::TreeTooLargeError, /more than 3 boards/
    )
  end

  it "counts the root toward max_boards" do
    2.times { |i| link(root, create(:board, user: user), position: i) }

    expect { walk(max_boards: 3) }.not_to raise_error
    expect { walk(max_boards: 2) }.to raise_error(described_class::TreeTooLargeError)
  end

  # The QR key is printed onto paper and can never be corrected, so the
  # fallback matters more than the happy path.
  describe ".qr_key_for" do
    it "prefers the slug, which is what Board#public_url hands out" do
      root.update!(slug: "core-words")

      expect(described_class.qr_key_for(root)).to eq("core-words")
    end

    it "falls back to the id when the slug is blank" do
      root.update_column(:slug, "")

      expect(described_class.qr_key_for(root)).to eq(root.id)
    end

    it "falls back to the id when the slug is nil" do
      root.update_column(:slug, nil)

      expect(described_class.qr_key_for(root)).to eq(root.id)
    end

    # Both forms have to resolve, or a printed QR 404s. BoardsController#set_board
    # tries find_by(id:) then find_by(slug:) — this pins that contract.
    it "produces a key /pb/ can resolve either way" do
      root.update!(slug: "core-words")

      expect(Board.find_by(id: root.id) || Board.find_by(slug: root.id)).to eq(root)
      expect(Board.find_by(id: "core-words") || Board.find_by(slug: "core-words")).to eq(root)
    end
  end
end
