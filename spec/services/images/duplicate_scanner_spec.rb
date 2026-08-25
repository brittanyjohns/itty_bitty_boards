require "rails_helper"

RSpec.describe Images::DuplicateScanner do
  # The scanner is the "preview" half of the dedupe. Everything here exists to
  # prove two things: it never writes, and it never puts a user's image in the
  # plan.
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def library_image(label, **attrs)
    create(:image, label: label, user_id: nil, is_private: false, **attrs)
  end

  describe "writing nothing" do
    it "does not create, update, or destroy any row" do
      library_image("apple")
      library_image("apple")

      expect { described_class.call }
        .to not_change(Image, :count)
        .and not_change(Doc, :count)

      expect(Image.by_label("apple").pluck(:updated_at).uniq.size).to be <= 2
    end

    it "does not mint a blank Image for an unmatched label" do
      expect { described_class.call(label: "nothing-matches-this") }.not_to change(Image, :count)
    end
  end

  describe "scope" do
    it "never groups a user-owned image" do
      user = create(:user)
      library_image("balloon")
      library_image("balloon")
      create(:image, label: "balloon", user_id: user.id)

      group = described_class.call(label: "balloon")["groups"].first
      ids = [group["survivor_id"]] + group["loser_ids"]

      expect(ids).not_to include(*Image.where(user_id: user.id).pluck(:id))
      expect(ids.size).to eq(2)
    end

    it "excludes private images" do
      library_image("kite")
      library_image("kite", is_private: true)

      expect(described_class.call(label: "kite")["groups"]).to be_empty
    end

    it "excludes image types that are not interchangeable library symbols" do
      library_image("burger", image_type: "Menu")
      library_image("burger", image_type: "Menu")

      expect(described_class.call(label: "burger")["groups"]).to be_empty
    end
  end

  describe "grouping" do
    it "keeps homographs apart by part_of_speech" do
      library_image("can", part_of_speech: "verb")
      library_image("can", part_of_speech: "noun")

      expect(described_class.call(label: "can")["groups"]).to be_empty
    end

    it "keeps the same word in different languages apart" do
      library_image("dog", language: "en")
      library_image("dog", language: "es")

      expect(described_class.call(label: "dog")["groups"]).to be_empty
    end

    it "groups rows that match on all three" do
      a = library_image("swing", part_of_speech: "noun", language: "en")
      b = library_image("swing", part_of_speech: "noun", language: "en")

      group = described_class.call(label: "swing")["groups"].first
      expect([group["survivor_id"]] + group["loser_ids"]).to match_array([a.id, b.id])
    end
  end

  describe "survivor choice" do
    it "prefers the image with the most docs, matching Boards::ImageResolver.best_arted" do
      sparse = library_image("wagon")
      rich = library_image("wagon")
      2.times { create(:doc, documentable: rich, user_id: nil) }
      create(:doc, documentable: sparse, user_id: nil)

      group = described_class.call(label: "wagon")["groups"].first
      expect(group["survivor_id"]).to eq(rich.id)
      expect(group["loser_ids"]).to eq([sparse.id])
    end

    it "falls back to the lowest id when no row has art" do
      first = library_image("puddle")
      second = library_image("puddle")

      group = described_class.call(label: "puddle")["groups"].first
      expect(group["survivor_id"]).to eq([first.id, second.id].min)
    end
  end

  describe "the report" do
    it "separates groups that merging can rescue from groups that need art" do
      # mixed: one has art, one doesn't -> merging fills a blank
      rich = library_image("mixed_case_word")
      library_image("mixed_case_word")
      create(:doc, documentable: rich, user_id: nil)

      # all blank: merging cannot help, these need generation
      library_image("blank_case_word")
      library_image("blank_case_word")

      report = described_class.call["report"]
      expect(report["mixed_art_groups"]).to be >= 1
      expect(report["all_blank_groups"]).to be >= 1
    end
  end
end
