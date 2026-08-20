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
#  display_label       :string
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

  describe "label / display_label split" do
    it "stores label as a lowercase, stripped matching key" do
      image = FactoryBot.create(:image, label: "  Swing  ")

      expect(image.label).to eq("swing")
    end

    it "keeps the authored casing in display_label" do
      image = FactoryBot.create(:image, label: "iPad")

      expect(image.label).to eq("ipad")
      expect(image.display_label).to eq("iPad")
    end

    it "preserves punctuation in the matching key" do
      image = FactoryBot.create(:image, label: "McDonald's")

      expect(image.label).to eq("mcdonald's")
      expect(image.display_label).to eq("McDonald's")
    end

    it "does not overwrite a display_label the caller supplied explicitly" do
      image = FactoryBot.create(:image, label: "tv", display_label: "TV")

      expect(image.label).to eq("tv")
      expect(image.display_label).to eq("TV")
    end

    it "re-derives display_label when the label is renamed" do
      image = FactoryBot.create(:image, label: "Swing")
      image.update!(label: "Slide")

      expect(image.label).to eq("slide")
      # Folded, not preserved: a plain leading capital is accidental. The
      # example above this one covers the casing that IS deliberate ("TV").
      expect(image.display_label).to eq("slide")
    end

    it "keeps an explicit display_label set in the same write as a rename" do
      image = FactoryBot.create(:image, label: "swing")
      image.update!(label: "ipad", display_label: "iPad")

      expect(image.label).to eq("ipad")
      expect(image.display_label).to eq("iPad")
    end

    it "falls back to label when display_label was never stored" do
      image = FactoryBot.create(:image, label: "swing")
      image.update_column(:display_label, nil)

      expect(image.reload.display_label).to eq("swing")
    end
  end

  describe ".by_label" do
    it "matches regardless of the casing the caller typed" do
      image = FactoryBot.create(:image, label: "swing")

      expect(Image.by_label("Swing")).to include(image)
      expect(Image.by_label("SWING")).to include(image)
      expect(Image.by_label("  swing ")).to include(image)
    end

    # The bug this whole change exists to kill: a case-sensitive lookup missed
    # the curated image and the calling site's next line minted a blank twin.
    it "finds the curated image a case-sensitive find_by would have missed" do
      curated = FactoryBot.create(:image, label: "swing")

      expect(Image.find_by(label: "Swing")).to be_nil
      expect(Image.by_label("Swing").first).to eq(curated)
    end

    it "does not match a different label" do
      FactoryBot.create(:image, label: "swing")

      expect(Image.by_label("slide")).to be_empty
    end

    it "is chainable with other scopes" do
      mine = FactoryBot.create(:image, label: "swing", user_id: 42)
      FactoryBot.create(:image, label: "swing", user_id: 99)

      expect(Image.by_label("Swing").find_by(user_id: 42)).to eq(mine)
    end
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

  # The src_url cascade routes through Images::TileArtFanout. Nothing on a bare
  # `image.save` names an actor, so an unattributed library change reaches
  # admin-owned boards only — it can keep the shared library's own boards
  # populated and can reach nobody else's. Callers that legitimately want the
  # acting user's boards updated set `fanout_actor_id`.
  describe "#update_board_images_display_image" do
    let(:user)  { FactoryBot.create(:user) }
    let!(:admin) do
      User.find_by(id: User::DEFAULT_ADMIN_ID) ||
        FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    end
    let(:board) { FactoryBot.create(:board, user: user) }
    let(:admin_board) { FactoryBot.create(:board, user: admin) }
    let(:image) { FactoryBot.create(:image, user: user) }
    let!(:board_image) do
      FactoryBot.create(:board_image, board: board, image: image, skip_create_voice_audio: true)
    end
    let!(:admin_board_image) do
      FactoryBot.create(:board_image, board: admin_board, image: image, skip_create_voice_audio: true)
    end
    let(:old_url) { "https://cdn.example.com/old.webp" }
    let(:new_url) { "https://cdn.example.com/new.webp" }

    before do
      # Set starting state via update_columns to avoid triggering callbacks
      image.update_columns(src_url: old_url)
      board_image.update_column(:display_image_url, old_url)
      admin_board_image.update_column(:display_image_url, old_url)
      image.board_images.reset
    end

    it "updates admin-owned tiles that still show the previous default URL" do
      image.update!(src_url: new_url)

      expect(admin_board_image.reload.display_image_url).to eq(new_url)
    end

    it "fills an admin-owned tile with a blank display_image_url" do
      admin_board_image.update_column(:display_image_url, nil)
      image.board_images.reset

      image.update!(src_url: new_url)

      expect(admin_board_image.reload.display_image_url).to eq(new_url)
    end

    it "does not reach a user's board when no actor is named" do
      image.update!(src_url: new_url)

      expect(board_image.reload.display_image_url).to eq(old_url)
    end

    it "reaches the acting user's own board when one is named" do
      image.fanout_actor_id = user.id
      image.update!(src_url: new_url)

      expect(board_image.reload.display_image_url).to eq(new_url)
    end

    # "" is the "this tile has no picture" marker, and it is blank AND not
    # present — both of the guards this code used to use got it wrong.
    it "never un-hides a deliberately blanked tile" do
      admin_board_image.update_column(:display_image_url, "")
      image.board_images.reset

      image.update!(src_url: new_url)

      expect(admin_board_image.reload.display_image_url).to eq("")
    end

    it "does not overwrite a user-custom URL that differs from the old src_url" do
      admin_board_image.update_column(:display_image_url, "https://cdn.example.com/user_custom_doc.webp")
      image.board_images.reset

      image.update!(src_url: new_url)

      expect(admin_board_image.reload.display_image_url)
        .to eq("https://cdn.example.com/user_custom_doc.webp")
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

    # "" is the "no picture" marker. `.present?` is false for it, so the old
    # guard treated a deliberately blanked tile as an empty one and re-showed
    # the picture — including under override_existing.
    it "does not un-hide a deliberately blanked tile, even with override" do
      tile_for(owner_board).update_column(:display_image_url, "")
      image.board_images.reset

      image.update_all_boards_image_belongs_to(new_url, true, owner.id)

      expect(tile_for(owner_board).reload.display_image_url).to eq("")
    end

    # The freshly minted URL is known-good, so it must not cost a network
    # round trip per tile to confirm it.
    it "does not validate the URL it was just handed" do
      expect(image).not_to receive(:authorized_to_view_url?).with(new_url)

      image.update_all_boards_image_belongs_to(new_url, false, owner.id)
    end
  end
end
