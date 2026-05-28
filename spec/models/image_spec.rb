# == Schema Information
#
# Table name: images
#
#  id                  :bigint           not null, primary key
#  label               :string
#  image_prompt        :text
#  display_description :text
#  private             :boolean
#  user_id             :integer
#  generate_image      :boolean          default(FALSE)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  status              :string
#  error               :string
#  revised_prompt      :string
#  image_type          :string
#  open_symbol_status  :string           default("active")
#  next_words          :string           default([]), is an Array
#  no_next             :boolean          default(FALSE)
#  part_of_speech      :string
#  bg_color            :string
#  text_color          :string
#  font_size           :integer
#  border_color        :string
#  is_private          :boolean          default(FALSE)
#  audio_url           :string
#  category            :string
#  use_custom_audio    :boolean          default(FALSE)
#  voice               :string
#  src_url             :string
#  data                :jsonb
#  license             :jsonb
#  obf_id              :string
#  language_settings   :jsonb
#  language            :string           default("en")
#
require "rails_helper"

RSpec.describe Image, type: :model do
  describe "#display_image_url" do
    let(:user) { FactoryBot.create(:user) }
    let(:admin_user) { FactoryBot.create(:user, role: "admin", id: User::DEFAULT_ADMIN_ID) }
    let(:image) { FactoryBot.create(:image, label: "test_image") }
    let(:doc) { FactoryBot.create(:doc, documentable: image) }

    context "when user is nil" do
      it "returns the image URL if doc exists" do
        url = image.display_image_url(nil)
        expect(url).to eq(doc.display_url)
      end

      it "returns nil if no doc exists" do
        image_without_doc = FactoryBot.create(:image, label: "no_doc_image")
        url = image_without_doc.display_image_url(nil)
        expect(url).to be_nil
      end
    end

    context "when user is an admin" do
      it "returns the image URL if doc exists" do
        url = image.display_image_url(admin_user)
        expect(url).to eq(doc.display_url)
      end

      it "returns nil if no doc exists" do
        image_without_doc = FactoryBot.create(:image, label: "no_doc_image")
        url = image_without_doc.display_image_url(admin_user)
        expect(url).to be_nil
      end
    end

    context "when user is a regular user" do
      it "returns the image URL if doc exists for that user" do
        user_specific_doc = FactoryBot.create(:doc, documentable: image, user: user)
        url = image.display_image_url(user)
        expect(url).to eq(user_specific_doc.display_url)
      end

      it "returns the public image URL if no user-specific doc exists but a public one does" do
        public_doc = FactoryBot.create(:doc, documentable: image, user: nil)
        url = image.display_image_url(user)
        expect(url).to eq(public_doc.display_url)
      end

      it "returns nil if no docs exist for that user or publicly" do
        image_without_doc = FactoryBot.create(:image, label: "no_doc_image")
        url = image_without_doc.display_image_url(user)
        expect(url).to be_nil
      end
    end
  end

  describe "#with_display_doc" do
    let(:user) { FactoryBot.create(:user) }
    let(:admin_user) { FactoryBot.create(:user, role: "admin", id: User::DEFAULT_ADMIN_ID) }
    let(:image) { FactoryBot.create(:image, label: "test_image") }
    let(:doc) { FactoryBot.create(:doc, documentable: image) }

    context ""
  end

  describe "#localized_label" do
    let(:image) do
      FactoryBot.create(:image,
                        label: "hello",
                        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end

    it "returns the English label when language is nil" do
      expect(image.localized_label(nil)).to eq("hello")
    end

    it "returns the English label when language is 'en'" do
      expect(image.localized_label("en")).to eq("hello")
    end

    it "returns the translated label when present in language_settings" do
      expect(image.localized_label("es")).to eq("hola")
    end

    it "falls back to English when the language is unsupported" do
      expect(image.localized_label("xx")).to eq("hello")
    end

    it "enqueues TranslateImageJob and returns English fallback when translation missing" do
      expect(TranslateImageJob).to receive(:perform_async).with(image.id, "fr")
      expect(image.localized_label("fr")).to eq("hello")
    end
  end

  describe "#localized_display_label" do
    let(:image) do
      FactoryBot.create(:image,
                        label: "hello",
                        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end

    it "returns the English label by default" do
      expect(image.localized_display_label(nil)).to eq("hello")
    end

    it "returns the translated display_label when present" do
      expect(image.localized_display_label("es")).to eq("Hola")
    end

    it "returns the translated label when only label is present" do
      image.update!(language_settings: { "es" => { "label" => "hola" } })
      expect(image.localized_display_label("es")).to eq("hola")
    end

    it "returns the translated label when only label is present" do
      image.update!(language_settings: { "es" => { "label" => "hola" } })
      expect(image.localized_display_label("es")).to eq("hola")
    end
  end

  describe "#text_for_audio" do
    let(:image) do
      FactoryBot.create(:image,
                        label: "hello",
                        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end

    it "returns the English label for 'en'" do
      expect(image.text_for_audio("en")).to eq("hello")
    end

    it "returns the English label when language is blank" do
      expect(image.text_for_audio("")).to eq("hello")
    end

    it "returns the translated label when a translation exists" do
      expect(image.text_for_audio("es")).to eq("hola")
    end

    it "falls back to the English label when no translation exists" do
      allow(TranslateImageJob).to receive(:perform_async)
      expect(image.text_for_audio("fr")).to eq("hello")
    end
  end

  describe ".normalize_label" do
    it "lowercases, strips, and removes diacritics" do
      expect(Image.normalize_label("  Perró  ")).to eq("perro")
    end

    it "returns empty string for blank input" do
      expect(Image.normalize_label(nil)).to eq("")
      expect(Image.normalize_label("")).to eq("")
    end
  end

  describe ".find_or_create_for_label" do
    let(:user) { FactoryBot.create(:user) }

    context "with English input" do
      it "returns the user's existing image when label matches" do
        owned = FactoryBot.create(:image, label: "dog", user_id: user.id)
        FactoryBot.create(:image, label: "dog", user_id: nil, is_private: false)
        result = Image.find_or_create_for_label("dog", language: "en", user: user)
        expect(result).to eq(owned)
      end

      it "falls back to a public image when the user has none" do
        public_image = FactoryBot.create(:image, label: "dog", user_id: nil, is_private: false)
        result = Image.find_or_create_for_label("dog", language: "en", user: user)
        expect(result).to eq(public_image)
      end

      it "creates a new English-canonical image when none exists" do
        expect {
          @image = Image.find_or_create_for_label("dog", language: "en", user: user)
        }.to change { Image.count }.by(1)
        expect(@image.label).to eq("dog")
        expect(@image.language).to eq("en")
        expect(@image.user_id).to eq(user.id)
      end
    end

    context "with Spanish input" do
      it "matches an existing image by its stored Spanish translation" do
        dog = FactoryBot.create(
          :image,
          label: "dog",
          user_id: nil,
          is_private: false,
          language_settings: { "es" => { "label" => "perro", "display_label" => "Perro" } },
        )
        result = Image.find_or_create_for_label("perro", language: "es", user: user)
        expect(result).to eq(dog)
      end

      it "matches case- and diacritic-insensitively" do
        dog = FactoryBot.create(
          :image,
          label: "dog",
          user_id: nil,
          is_private: false,
          language_settings: { "es" => { "label" => "perro", "display_label" => "Perro" } },
        )
        result = Image.find_or_create_for_label("Perró", language: "es", user: user)
        expect(result).to eq(dog)
      end

      it "translates input to English and matches on the canonical label" do
        cat = FactoryBot.create(:image, label: "cat", user_id: nil, is_private: false)
        allow(Image).to receive(:translate_to_english).with("gato", "es").and_return("cat")
        result = Image.find_or_create_for_label("gato", language: "es", user: user)
        expect(result).to eq(cat)
        expect(result.reload.language_settings.dig("es", "label")).to eq("gato")
      end

      it "creates a canonical English image when translation succeeds but no match exists" do
        allow(Image).to receive(:translate_to_english).with("gato", "es").and_return("cat")
        expect {
          @image = Image.find_or_create_for_label("gato", language: "es", user: user)
        }.to change { Image.count }.by(1)
        expect(@image.label).to eq("cat")
        expect(@image.language).to eq("en")
        expect(@image.language_settings.dig("es", "label")).to eq("gato")
      end

      it "falls back to creating with the raw input when translation fails" do
        allow(Image).to receive(:translate_to_english).with("gato", "es").and_return(nil)
        expect {
          @image = Image.find_or_create_for_label("gato", language: "es", user: user)
        }.to change { Image.count }.by(1)
        expect(@image.label).to eq("gato")
        expect(@image.language).to eq("es")
      end

      it "records the user's Spanish input on a match that lacked it" do
        cat = FactoryBot.create(:image, label: "cat", user_id: nil, is_private: false)
        allow(Image).to receive(:translate_to_english).with("gato", "es").and_return("cat")
        Image.find_or_create_for_label("gato", language: "es", user: user)
        expect(cat.reload.language_settings.dig("es", "label")).to eq("gato")
        expect(cat.language_settings.dig("es", "display_label")).to eq("Gato")
      end
    end

    it "returns nil for blank input" do
      expect(Image.find_or_create_for_label(nil, language: "es", user: user)).to be_nil
      expect(Image.find_or_create_for_label("   ", language: "es", user: user)).to be_nil
    end

    it "treats unknown languages as English" do
      FactoryBot.create(:image, label: "dog", user_id: nil, is_private: false)
      result = Image.find_or_create_for_label("dog", language: "xx", user: user)
      expect(result.label).to eq("dog")
    end
  end
end
