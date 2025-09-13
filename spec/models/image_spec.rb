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
end
