require "rails_helper"

RSpec.describe Boards::RobustSets, type: :service do
  # The seeder owns its boards as DEFAULT_ADMIN_ID and marks them predefined
  # (VocabSets.seed_slug!). Both are load-bearing for the lookup scope.
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def seed_root!(name:, slug:)
    board = create(:board, name: name, user: admin, predefined: true, published: true)
    described_class.mark_root!(board, slug)
  end

  describe ".display_name_for" do
    it "returns the authored constant for a known slug" do
      expect(described_class.display_name_for("core-84")).to eq("Core 84")
      expect(described_class.display_name_for("core-60")).to eq("Core 60")
    end

    it "derives a name from an unknown slug rather than reading a board" do
      expect(described_class.display_name_for("core-96")).to eq("Core 96")
    end

    it "is nil for a blank slug" do
      expect(described_class.display_name_for(nil)).to be_nil
      expect(described_class.display_name_for("")).to be_nil
    end
  end

  describe ".find_root" do
    let!(:seed) { seed_root!(name: "Core 84", slug: "core-84") }

    it "resolves the seeded root" do
      expect(described_class.find_root("core-84")).to eq(seed)
    end

    it "is nil for a slug that isn't seeded here" do
      expect(described_class.find_root("core-60")).to be_nil
    end

    # The bug: "Classroom — Core Words Poster" sorts before "Core 84", and the
    # lookup ordered by name, so a marketing clone won and renamed (and supplied
    # the grid for) every Extended build.
    it "is not won by an alphabetically-earlier clone of the seed" do
      stray = seed.clone_with_images(admin.id, "Classroom — Core Words Poster")
      # Re-stamp by hand: clone_with_images now strips the markers, but rows
      # cloned before that fix are still out there carrying them.
      stray.update_columns(settings: stray.settings.merge(
        described_class::ROOT_MARKER => true,
        described_class::SLUG_MARKER => "core-84",
      ))

      expect(described_class.find_root("core-84")).to eq(seed)
      expect(described_class.all_roots).not_to include(stray)
    end

    it "ignores a marked board owned by someone other than the seeder" do
      other = create(:board, name: "Aardvark Board", user: create(:user), predefined: true)
      other.update_columns(settings: { described_class::ROOT_MARKER => true,
                                       described_class::SLUG_MARKER => "core-84" })

      expect(described_class.find_root("core-84")).to eq(seed)
    end

    it "ignores a marked admin board that isn't predefined" do
      other = create(:board, name: "Aardvark Board", user: admin, predefined: false)
      other.update_columns(settings: { described_class::ROOT_MARKER => true,
                                       described_class::SLUG_MARKER => "core-84" })

      expect(described_class.find_root("core-84")).to eq(seed)
    end

    it "prefers the oldest seed when two legitimately carry the same slug" do
      later = seed_root!(name: "Aardvark 84", slug: "core-84")

      expect(described_class.find_root("core-84")).to eq(seed)
      expect(later.id).to be > seed.id
    end
  end
end
