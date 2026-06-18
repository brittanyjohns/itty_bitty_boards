require "rails_helper"

RSpec.describe Boards::ImageResolver do
  let(:owner) { create(:user) }
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def with_art(image)
    create(:doc, documentable: image, user: image.user || admin)
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
