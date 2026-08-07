require "rails_helper"

# Model-level backstop for the frozen published slug (#611). The guard is a
# before_save so it covers every caller — controllers, jobs, rake tasks — not
# just the API update path.
RSpec.describe Board, "published slug freeze", type: :model do
  let(:user) { create(:user) }

  # Slug first, publish second — the real order. A board gets its slug while
  # it's still a draft, and publishing is what freezes it.
  def board_with_slug(published:)
    board = create(:board, user: user, name: "Snack Time", published: false)
    board.generate_unique_slug
    board.save!
    board.update!(published: true) if published
    board
  end

  describe "#slug_locked?" do
    it "is true for a published board with a slug" do
      expect(board_with_slug(published: true).slug_locked?).to be true
    end

    it "is false for an unpublished board" do
      expect(board_with_slug(published: false).slug_locked?).to be false
    end

    it "is false for a published board that never got a slug" do
      board = create(:board, user: user, published: true, slug: "")
      # `slug` defaults to "" in the schema, so this is a real state.
      expect(board.slug_locked?).to be false
    end
  end

  describe "the before_save guard" do
    it "reverts a slug change on a published board" do
      board = board_with_slug(published: true)
      original_slug = board.slug

      board.slug = "something-else"
      board.save!

      expect(board.reload.slug).to eq(original_slug)
    end

    it "does not block the rest of the save" do
      board = board_with_slug(published: true)

      board.slug = "something-else"
      board.name = "Lunch Time"
      board.save!

      expect(board.reload.name).to eq("Lunch Time")
    end

    it "allows the change on an unpublished board" do
      board = board_with_slug(published: false)

      board.slug = "something-else"
      board.save!

      expect(board.reload.slug).to eq("something-else")
    end

    it "allows a slug set in the same save that publishes the board" do
      board = board_with_slug(published: false)

      board.slug = "ready-to-print"
      board.published = true
      board.save!

      expect(board.reload.slug).to eq("ready-to-print")
    end

    it "still fills in a blank slug on a published board" do
      board = create(:board, user: user, name: "No Slug Yet", published: true, slug: "")

      board.generate_unique_slug
      board.save!

      expect(board.reload.slug).to eq("no-slug-yet")
    end

    it "leaves new records alone" do
      board = build(:board, user: user, name: "Fresh", published: true)
      board.generate_unique_slug
      board.save!

      expect(board.reload.slug).to eq("fresh")
    end
  end

  describe "#rename_slug!" do
    it "is the deliberate escape hatch for a published board" do
      board = board_with_slug(published: true)

      expect(board.rename_slug!("deliberate-rename")).to be true
      expect(board.reload.slug).to eq("deliberate-rename")
    end

    it "re-locks the slug afterward" do
      board = board_with_slug(published: true)
      board.rename_slug!("deliberate-rename")

      board.slug = "sneaky-follow-up"
      board.save!

      expect(board.reload.slug).to eq("deliberate-rename")
    end

    it "still de-duplicates against an existing slug" do
      create(:board, user: user, slug: "taken", published: false)
      board = board_with_slug(published: true)

      board.rename_slug!("taken")

      expect(board.reload.slug).to start_with("taken-")
    end
  end
end
