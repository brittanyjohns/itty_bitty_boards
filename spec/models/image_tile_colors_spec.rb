require "rails_helper"

RSpec.describe Image, "tile colors" do
  # The global AacWordCategorizer stub (spec/support/stub_aac_categorizer.rb)
  # returns "noun" for every label, so a freshly created image is orange.
  let(:image) { FactoryBot.create(:image, label: "my turn") }

  describe "refreshing bg_color when part_of_speech changes" do
    it "repaints the image when the category is corrected" do
      expect(image.reload.part_of_speech).to eq("noun")
      expect(image.bg_color).to eq("#FFC457")

      image.update!(part_of_speech: "social")

      expect(image.reload.part_of_speech).to eq("social")
      expect(image.bg_color).to eq("#FF99B8")
      expect(image.text_color).to eq("#000000")
    end

    it "repaints important_function red" do
      image.update!(part_of_speech: "important_function")

      expect(image.reload.bg_color).to eq("#FF7070")
    end

    it "does not repaint when part_of_speech is unchanged" do
      image.update_columns(bg_color: "#123456")
      image.skip_categorize = true
      image.update!(label: "my turn now")

      expect(image.reload.bg_color).to eq("#123456")
    end
  end

  describe "ensure_defaults" do
    it "preserves an explicitly assigned part_of_speech through an ordinary save" do
      image.part_of_speech = "pronoun"
      image.save!

      expect(image.reload.part_of_speech).to eq("pronoun")
      expect(image.bg_color).to eq("#FFEA75")
    end

    it "does not call the categorizer when the category was assigned by hand" do
      image # create first, so the create-path categorization is already done
      expect(AacWordCategorizer).not_to receive(:categorize)

      image.update!(part_of_speech: "adverb")
    end

    it "still categorizes a save that does not touch part_of_speech" do
      image
      expect(AacWordCategorizer).to receive(:categorize).with("my turn").and_return("verb")

      image.update!(label: "my turn")

      expect(image.reload.part_of_speech).to eq("verb")
      expect(image.bg_color).to eq("#A1F571")
    end

    it "respects a bg_color assigned in the same save as the category" do
      image.assign_attributes(part_of_speech: "pronoun", bg_color: "#123456")
      image.save!

      expect(image.reload.bg_color).to eq("#123456")
    end
  end

  describe "menu images" do
    # A menu item is a dish, not AAC vocabulary: no Fitzgerald colour, and no
    # categorizer call (which is a synchronous OpenAI request).
    it "is white with no category and never calls the categorizer" do
      expect(AacWordCategorizer).not_to receive(:categorize)

      menu_image = FactoryBot.create(:image, label: "virginia", image_type: "menu")

      expect(menu_image.reload.bg_color).to eq("#FFFFFF")
      expect(menu_image.text_color).to eq("#000000")
      expect(menu_image.part_of_speech).to eq("default")
    end

    it "stays white across a later save" do
      menu_image = FactoryBot.create(:image, label: "single", image_type: "menu")

      menu_image.update!(label: "single burger")

      expect(menu_image.reload.bg_color).to eq("#FFFFFF")
    end

    it "stays white when update_all_background_colors sweeps it" do
      menu_image = FactoryBot.create(:image, label: "biscuit", image_type: "menu")

      Image.update_all_background_colors

      expect(menu_image.reload.bg_color).to eq("#FFFFFF")
    end

    it "recognizes the legacy capitalized image_type" do
      menu_image = FactoryBot.create(:image, label: "ham", image_type: "Menu")

      expect(menu_image.reload.bg_color).to eq("#FFFFFF")
      expect(menu_image).to be_menu
    end
  end
end
