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

  describe "#display_doc" do
    let(:user) { create(:user) }

    it "returns the same doc whether or not preloaded_user_docs is supplied" do
      image = create(:image, label: "cup", user: user)
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)

      without_preload = image.display_doc(user)
      preloaded = user.user_docs.includes(:doc).where(image_id: image.id).group_by(&:image_id)
      with_preload = image.display_doc(user, preloaded_user_docs: preloaded)

      expect(with_preload).to eq(without_preload)
      expect(with_preload).to eq(doc)
    end

    it "falls back to the existing per-image query when preloaded_user_docs has no entry for this image" do
      image = create(:image, label: "cup", user: user)
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)

      expect(image.display_doc(user, preloaded_user_docs: {})).to eq(doc)
    end

    it "does not change resolution for the DEFAULT_ADMIN_ID special case" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      image = create(:image, label: "cup", user: admin)
      doc = create(:doc, documentable: image, user: admin, source_type: Doc::SOURCE_TYPE_USER, current: true)

      expect(image.display_doc(admin, preloaded_user_docs: { image.id => [] })).to eq(doc)
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

  describe "#update_board_images_display_image" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }
    let(:image) { FactoryBot.create(:image, user: user) }
    let!(:board_image) do
      FactoryBot.create(:board_image, board: board, image: image, skip_create_voice_audio: true)
    end

    before do
      # Set starting state via update_columns to avoid triggering callbacks
      image.update_columns(src_url: "https://cdn.example.com/old.webp")
      board_image.update_column(:display_image_url, "https://cdn.example.com/old.webp")
    end

    it "updates tiles that still show the previous default URL" do
      image.update!(src_url: "https://cdn.example.com/new.webp")

      board_image.reload
      expect(board_image.display_image_url).to eq("https://cdn.example.com/new.webp")
    end

    it "fills tiles with a blank display_image_url" do
      board_image.update_column(:display_image_url, nil)
      image.board_images.reset

      image.update!(src_url: "https://cdn.example.com/new.webp")

      board_image.reload
      expect(board_image.display_image_url).to eq("https://cdn.example.com/new.webp")
    end

    it "does not overwrite a user-custom URL that differs from the old src_url" do
      board_image.update_column(:display_image_url, "https://cdn.example.com/user_custom_doc.webp")

      image.update!(src_url: "https://cdn.example.com/new.webp")

      board_image.reload
      expect(board_image.display_image_url).to eq("https://cdn.example.com/user_custom_doc.webp")
    end
  end

  describe "#update_all_boards_image_belongs_to" do
    # Images are shared library records, so an unscoped sweep would let one
    # user's regeneration repoint tiles on another user's boards.
    let(:owner) { FactoryBot.create(:user) }
    let(:stranger) { FactoryBot.create(:user) }
    let(:image) { FactoryBot.create(:image, user: owner, label: "apple") }
    let(:owner_board) { FactoryBot.create(:board, user: owner) }
    let(:stranger_board) { FactoryBot.create(:board, user: stranger) }
    let(:new_url) { "https://cdn.example.com/fresh.webp" }

    before do
      owner_board.add_image(image.id)
      stranger_board.add_image(image.id)
      image.board_images.each { |bi| bi.update_column(:display_image_url, nil) }
      image.board_images.reset
    end

    def tile_for(board)
      image.board_images.find_by(board_id: board.id)
    end

    it "repoints the generating user's own empty tiles" do
      image.update_all_boards_image_belongs_to(new_url, false, owner.id)

      expect(tile_for(owner_board).reload.display_image_url).to eq(new_url)
    end

    it "leaves another user's tiles alone" do
      image.update_all_boards_image_belongs_to(new_url, false, owner.id)

      expect(tile_for(stranger_board).reload.display_image_url).to be_nil
    end

    it "still fills admin-owned tiles so the shared library stays populated" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) ||
              FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      admin_board = FactoryBot.create(:board, user: admin)
      admin_board.add_image(image.id)
      image.board_images.reset
      tile_for(admin_board).update_column(:display_image_url, nil)

      image.update_all_boards_image_belongs_to(new_url, false, owner.id)

      expect(tile_for(admin_board).reload.display_image_url).to eq(new_url)
    end

    it "does nothing when there is no URL to point at" do
      expect(image.update_all_boards_image_belongs_to(nil, false, owner.id)).to eq([])
      expect(tile_for(owner_board).reload.display_image_url).to be_nil
    end

    # The freshly minted URL is known-good, so it must not cost a network
    # round trip per tile to confirm it.
    it "does not validate the URL it was just handed" do
      expect(image).not_to receive(:authorized_to_view_url?).with(new_url)

      image.update_all_boards_image_belongs_to(new_url, false, owner.id)
    end
  end
end
