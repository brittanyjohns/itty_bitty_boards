require "rails_helper"

RSpec.describe Boards::StarterBlueprints, type: :service do
  let(:user) { create(:user) }

  def all_tiles(node)
    Array(node[:tiles]).flat_map do |tile|
      [tile] + (tile[:children] ? all_tiles(tile[:children]) : [])
    end
  end

  describe ".for" do
    it "returns nil for an unknown template key" do
      expect(described_class.for("not_a_template", user)).to be_nil
    end

    context "with no images seeded (the staging outage scenario)" do
      it "self-heals: builds the blueprint, creating a blank-art image per label" do
        # Regression for the 500 RuntimeError("no Image for label \"Food\"").
        blueprint = nil
        expect {
          blueprint = described_class.for("home", user)
        }.not_to raise_error

        all_tiles(blueprint).each { |t| expect(t[:image_id]).to be_a(Integer) }

        # The capitalized folder labels — folder names, never seeded vocabulary —
        # are exactly what used to blow up. They now resolve to created images.
        %w[Food Feelings Play].each do |folder_label|
          expect(Image.find_by(label: folder_label, user_id: user.id)).to be_present
        end
      end
    end

    context "with a label already owned by the user" do
      it "reuses the existing image instead of creating a duplicate" do
        existing = create(:image, label: "Food", user_id: user.id)

        expect {
          described_class.for("home", user)
        }.not_to change { Image.where(label: "Food").count }

        food = described_class.for("home", user)[:tiles].find { |t| t[:label] == "Food" }
        expect(food[:image_id]).to eq(existing.id)
      end
    end

    context "with a label available as a public image" do
      it "reuses the public image rather than creating a private duplicate" do
        public_img = create(:image, label: "water", user_id: nil, is_private: false)

        expect {
          described_class.for("home", user)
        }.not_to change { Image.where(label: "water").count }

        water = all_tiles(described_class.for("home", user)).find { |t| t[:label] == "water" }
        expect(water[:image_id]).to eq(public_img.id)
      end
    end
  end
end
