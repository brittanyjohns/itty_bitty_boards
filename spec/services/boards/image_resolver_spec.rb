require "rails_helper"

RSpec.describe Boards::ImageResolver do
  let(:owner) { create(:user) }
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def with_art(image, count: 1)
    count.times { create(:doc, documentable: image, user: image.user || admin) }
    image
  end

  describe ".resolve" do
    it "prefers a public/admin image that has art over a blank same-label image" do
      blank = create(:image, label: "animals", user_id: admin.id)         # lower id, no art
      arted = with_art(create(:image, label: "animals", user_id: admin.id)) # higher id, has art

      result = described_class.resolve("Animals", owner: owner)

      expect(result).to eq(arted)
      expect(result).not_to eq(blank)
    end

    it "prefers the owner's own art-bearing image over a public one" do
      with_art(create(:image, label: "dog", user_id: admin.id))
      owner_art = with_art(create(:image, label: "dog", user_id: owner.id))

      expect(described_class.resolve("dog", owner: owner)).to eq(owner_art)
    end

    it "falls back to an existing blank image when no art exists for the label" do
      blank = create(:image, label: "zzz_niche", user_id: admin.id)

      expect(described_class.resolve("zzz_niche", owner: owner)).to eq(blank)
    end

    it "creates an owner-owned blank image when none exists for the label" do
      expect {
        result = described_class.resolve("brand_new_word", owner: owner)
        expect(result.label).to eq("brand_new_word")
        expect(result.user_id).to eq(owner.id)
      }.to change(Image, :count).by(1)
    end

    it "normalizes the label before resolving" do
      arted = with_art(create(:image, label: "feelings", user_id: admin.id))
      expect(described_class.resolve("Feelings", owner: owner)).to eq(arted)
    end

    it "prefers the admin 'default' image with the MOST docs over a thinner one" do
      few  = with_art(create(:image, label: "ball", user_id: admin.id), count: 1)
      many = with_art(create(:image, label: "ball", user_id: admin.id), count: 3)

      result = described_class.resolve("ball", owner: owner)

      expect(result).to eq(many)
      expect(result).not_to eq(few)
    end
  end

  describe ".best_arted_for" do
    it "returns nil and creates nothing when no art exists for the label" do
      create(:image, label: "no_art_here", user_id: admin.id)

      expect {
        expect(described_class.best_arted_for("No_Art_Here", owner)).to be_nil
      }.not_to change(Image, :count)
    end
  end

  describe ".upgrade_board_tiles!" do
    let(:board) { create(:board, user: owner) }

    it "re-points a blank tile to the curated art image for its label, keeping the authored label" do
      blank = create(:image, label: "animals", user_id: admin.id)
      arted = with_art(create(:image, label: "animals", user_id: admin.id))
      tile  = board.add_image(blank.id)
      tile.update_columns(label: "Animals", display_label: "Animals")

      described_class.upgrade_board_tiles!(board, owner: owner)

      tile.reload
      expect(tile.image_id).to eq(arted.id)
      expect(tile.label).to eq("Animals")
      expect(tile.display_label).to eq("Animals")
    end

    it "leaves a tile that already has art untouched" do
      arted = with_art(create(:image, label: "dog", user_id: admin.id))
      other = with_art(create(:image, label: "dog", user_id: admin.id), count: 5)
      tile  = board.add_image(arted.id)

      described_class.upgrade_board_tiles!(board, owner: owner)

      expect(tile.reload.image_id).to eq(arted.id)
      expect(tile.image_id).not_to eq(other.id)
    end

    it "leaves a blank tile blank when no art exists for the label" do
      blank = create(:image, label: "niche_word", user_id: admin.id)
      tile  = board.add_image(blank.id)

      expect {
        described_class.upgrade_board_tiles!(board, owner: owner)
      }.not_to change(Image, :count)
      expect(tile.reload.image_id).to eq(blank.id)
    end
  end

  describe ".art?" do
    it "is true when the image has a doc" do
      expect(described_class.art?(with_art(create(:image, user_id: admin.id)))).to be(true)
    end

    it "is false for a blank image and for nil" do
      expect(described_class.art?(create(:image, user_id: admin.id))).to be(false)
      expect(described_class.art?(nil)).to be(false)
    end
  end
end
