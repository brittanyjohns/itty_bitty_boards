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
  describe ".destroy_duplicate_images" do
    let!(:image1) { FactoryBot.create(:image, label: "duplicate", created_at: 2.days.ago) }
    let!(:image2) { FactoryBot.create(:image, label: "duplicate", created_at: 1.day.ago) }
    let!(:doc1) { FactoryBot.create(:doc, documentable: image1) }
    let!(:doc2) { FactoryBot.create(:doc, documentable: image2) }
    let!(:doc3) { FactoryBot.create(:doc, documentable: image2) } # Additional doc attached to image2

    # Simulate S3 attachments
    before do
      allow(doc1).to receive_message_chain(:image, :purge).and_return(true)
      allow(doc2).to receive_message_chain(:image, :purge).and_return(true)
      allow(doc3).to receive_message_chain(:image, :purge).and_return(true)
    end

    context "when there are duplicate images with more than two docs" do
      it "destroys the duplicate images" do
        expect {
          Image.destroy_duplicate_images(dry_run: false)
        }.to change { Image.count }.by(-1)
      end

      it "does not destroy the non-duplicate image" do
        Image.destroy_duplicate_images(dry_run: false)
        expect(Image.exists?(image1.id)).to be_truthy
        expect(Image.exists?(image2.id)).to be_falsey
      end

      it "reassigns all docs to the kept image" do
        Image.destroy_duplicate_images(dry_run: false)
        expect(doc1.reload.documentable_id).to eq(image1.id)
        expect(doc2.reload.documentable_id).to eq(image1.id)
        expect(doc3.reload.documentable_id).to eq(image1.id)
      end

      it "does not delete docs" do
        expect {
          Image.destroy_duplicate_images(dry_run: false)
        }.not_to change { Doc.count }

        expect(Doc.exists?(doc1.id)).to be_truthy
        expect(Doc.exists?(doc2.id)).to be_truthy
        expect(Doc.exists?(doc3.id)).to be_truthy
      end

      it "does not purge attachments from S3" do
        expect(doc1.image).not_to receive(:purge)
        expect(doc2.image).not_to receive(:purge)
        expect(doc3.image).not_to receive(:purge)
        Image.destroy_duplicate_images(dry_run: false)
      end
    end

    context "when dry_run is true with more than two docs" do
      it "does not destroy images" do
        expect {
          Image.destroy_duplicate_images(dry_run: true)
        }.not_to change { Image.count }
      end

      it "does not reassign docs" do
        expect {
          Image.destroy_duplicate_images(dry_run: true)
        }.not_to change { doc2.reload.documentable_id }
        expect {
          Image.destroy_duplicate_images(dry_run: true)
        }.not_to change { doc3.reload.documentable_id }
      end

      it "does not delete docs" do
        expect {
          Image.destroy_duplicate_images(dry_run: true)
        }.not_to change { Doc.count }
      end

      it "does not purge attachments from S3" do
        expect(doc1.image).not_to receive(:purge)
        expect(doc2.image).not_to receive(:purge)
        expect(doc3.image).not_to receive(:purge)
        Image.destroy_duplicate_images(dry_run: true)
      end
    end
  end
end
