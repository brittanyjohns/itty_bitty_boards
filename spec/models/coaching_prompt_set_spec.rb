require "rails_helper"

RSpec.describe CoachingPromptSet, type: :model do
  describe "validations" do
    it "requires name, slug, source" do
      set = CoachingPromptSet.new
      expect(set).not_to be_valid
      expect(set.errors[:name]).to be_present
      expect(set.errors[:slug]).to be_present
    end

    it "enforces unique slugs" do
      build(:coaching_prompt_set, slug: "x").tap(&:save!)
      dup = build(:coaching_prompt_set, slug: "x")
      expect(dup).not_to be_valid
    end

    it "rejects unknown sources" do
      set = build(:coaching_prompt_set, source: "bogus")
      expect(set).not_to be_valid
    end
  end

  describe ".match_for" do
    let(:user) { create(:user) }
    let(:board) { create(:board, user: user, parent_id: user.id, parent_type: "User") }

    let!(:snack_set) do
      create(:coaching_prompt_set,
        slug: "rspec_snack_set",
        match_tags: %w[rspec_snack_tag rspec_food_tag],
        published: true)
    end

    let!(:car_set) do
      create(:coaching_prompt_set,
        slug: "rspec_car_set",
        match_tags: %w[rspec_car_tag rspec_drive_tag],
        published: true)
    end

    it "returns the curated set that matches a board tag" do
      board.update!(tags: ["rspec_snack_tag"])
      expect(described_class.match_for(board)).to eq(snack_set)
    end

    it "returns nil when no tag matches and no name match" do
      board.update!(tags: ["unrelated"], name: "Random Random")
      expect(described_class.match_for(board)).to be_nil
    end

    it "falls back to matching against tokens in the board name" do
      board.update!(tags: [], name: "Rspec_car_tag Vehicle")
      expect(described_class.match_for(board)).to eq(car_set)
    end

    it "ignores unpublished sets" do
      snack_set.update!(published: false)
      board.update!(tags: ["rspec_snack_tag"])
      expect(described_class.match_for(board)).to be_nil
    end

    it "ignores ai_generated sets even when tags match" do
      snack_set.update!(source: "ai_generated")
      board.update!(tags: ["rspec_snack_tag"])
      expect(described_class.match_for(board)).to be_nil
    end

    it "respects board language" do
      board.update!(tags: ["rspec_snack_tag"], language: "es")
      expect(described_class.match_for(board)).to be_nil
    end
  end

  describe "#editable_by?" do
    let(:owner) { create(:user) }
    let(:other) { create(:user) }
    let(:admin) { create(:admin_user) }

    it "is true for the owner" do
      set = create(:coaching_prompt_set, user: owner)
      expect(set.editable_by?(owner)).to be true
    end

    it "is false for a different signed-in user" do
      set = create(:coaching_prompt_set, user: owner)
      expect(set.editable_by?(other)).to be false
    end

    it "is true for admins regardless of owner" do
      set = create(:coaching_prompt_set, user: owner)
      expect(set.editable_by?(admin)).to be true
    end

    it "is false for SpeakAnyWay-shipped sets (no user)" do
      set = create(:coaching_prompt_set, user: nil)
      expect(set.editable_by?(owner)).to be false
    end
  end
end
