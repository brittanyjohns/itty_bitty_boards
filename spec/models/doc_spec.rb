# == Schema Information
#
# Table name: docs
#
#  id                 :bigint           not null, primary key
#  documentable_type  :string           not null
#  documentable_id    :bigint           not null
#  processed          :text
#  raw                :text
#  current            :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  board_id           :integer
#  user_id            :integer
#  source_type        :string
#  deleted_at         :datetime
#  original_image_url :string
#  prompt_for_prompt  :string
#  data               :jsonb
#  license            :jsonb
#
require "rails_helper"

RSpec.describe Doc, type: :model do
  # describe ".clean_up_broken_urls" do
  #   let!(:doc1) { FactoryBot.create(:doc) }
  #   let!(:doc2) { FactoryBot.create(:doc) }
  #   let!(:doc3) { FactoryBot.create(:doc) }

  #   before do
  #     # Simulate attached images for doc1 and doc2
  #     allow(doc1).to receive_message_chain(:image, :attached?).and_return(true)
  #     allow(doc2).to receive_message_chain(:image, :attached?).and_return(true)
  #     allow(doc3).to receive_message_chain(:image, :attached?).and_return(false)  # doc3 has no attached image

  #     # Simulate URL for doc1 and doc2
  #     allow(doc1).to receive(:display_url).and_return("https://valid-url.com/image1.png")
  #     allow(doc2).to receive(:display_url).and_return(nil)  # Broken URL for doc2
  #     allow(doc3).to receive(:display_url).and_return(nil)  # No URL for doc3

  #     allow(doc1.image).to receive(:purge).and_return(true)
  #     allow(doc2.image).to receive(:purge).and_return(true)
  #   end

  #   subject { Doc.clean_up_broken_urls }

  #   before do
  #     subject
  #   end

  #   it "marks docs with broken URLs as hidden using soft delete" do
  #     expect(doc2.reload.deleted_at).not_to be_nil
  #     expect(doc3.reload.deleted_at).not_to be_nil
  #   end

  #   it "does not purge attachments from S3 for valid URLs" do
  #     expect(doc1.image).not_to receive(:purge)
  #   end

  #   it "does not purge attachments from S3 for broken URLs" do
  #     expect(doc2.image).not_to receive(:purge)
  #   end

  #   it "does not purge attachments from S3 for docs with no attached image" do
  #     expect(doc3.image).not_to receive(:purge)
  #   end
  # end

  describe ".for_user" do
    let(:user) { FactoryBot.create(:user) }
    let(:other_user) { FactoryBot.create(:user) }
    let!(:admin_user) { FactoryBot.create(:user, role: "admin", id: User::DEFAULT_ADMIN_ID) }
    let!(:doc1) { FactoryBot.create(:doc, user: user) }
    let!(:doc2) { FactoryBot.create(:doc, user: other_user) }
    let!(:doc3) { FactoryBot.create(:doc, user: nil) }
    let!(:doc4) { FactoryBot.create(:doc, user: admin_user) }

    it "returns docs belonging to the specified user or with no user" do
      result = Doc.for_user(user)
      expect(result).to include(doc1)
      expect(result).to include(doc3)
      expect(result).not_to include(doc2)
      expect(result).to include(doc4)
    end
  end

  # Rendering a tile variant inside an open transaction is fatal, not slow: the
  # variant's bytes are uploaded from an after_commit callback, and
  # image_processing's tempfile is unlinked as soon as the transform block
  # returns. Deferred to an outer commit, the upload reads a path that is gone
  # and the job dies on Errno::ENOENT @ rb_file_s_size (#700).
  describe "tile variant rendering" do
    let(:user) { FactoryBot.create(:user) }
    let(:image) { FactoryBot.create(:image, label: "apple", user: user) }
    let(:doc) do
      FactoryBot.create(:doc, documentable: image, user: user, current: true).tap do |d|
        d.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                       filename: "tile.png", content_type: "image/png")
      end
    end

    before { PreprocessDocTileVariantJob.clear }

    context "with no transaction open" do
      it "renders the variant inline and reports it available" do
        expect(doc.ensure_tile_variant!).to be(true)
        expect(doc.tile_variant_processed?).to be(true)
      end

      # Asserted as "not the original", not by url shape: tile_url serves a CDN
      # url built from the variant key when CDN_HOST is set and a routed
      # representation url when it isn't, and CI has neither set.
      it "returns the variant's url from #tile_url" do
        url = doc.tile_url

        expect(url).to be_present
        expect(url).not_to eq(doc.display_url)
        expect(doc.tile_variant_processed?).to be(true)
      end

      it "is a no-op once the variant exists" do
        doc.ensure_tile_variant!

        expect { doc.ensure_tile_variant! }
          .not_to change { PreprocessDocTileVariantJob.jobs.size }
      end
    end

    context "with a transaction open" do
      it "does not render the variant" do
        doc # attach outside the transaction

        ActiveRecord::Base.transaction do
          expect(doc.ensure_tile_variant!).to be(false)
          expect(doc.tile_variant_processed?).to be(false)
        end
      end

      it "queues the render for after the commit, not from inside it" do
        doc

        ActiveRecord::Base.transaction do
          doc.ensure_tile_variant!
          expect(PreprocessDocTileVariantJob.jobs.size).to eq(0)
        end

        expect(PreprocessDocTileVariantJob.jobs.size).to eq(1)
        expect(PreprocessDocTileVariantJob.jobs.last["args"]).to eq([doc.id])
      end

      it "never queues a render for a transaction that rolled back" do
        doc

        ActiveRecord::Base.transaction do
          doc.ensure_tile_variant!
          raise ActiveRecord::Rollback
        end

        expect(PreprocessDocTileVariantJob.jobs.size).to eq(0)
      end

      # Time is frozen only so the two urls are comparable: with no CDN_HOST set
      # these are signed disk urls carrying an expiry, so the same url built a
      # millisecond apart is a different string.
      it "falls back to the original image url from #tile_url" do
        doc

        freeze_time do
          ActiveRecord::Base.transaction do
            url = doc.tile_url
            expect(url).to be_present
            expect(url).to eq(doc.display_url)
            expect(doc.tile_variant_processed?).to be(false)
          end
        end
      end

      it "still serves the variant url once it has been rendered" do
        doc.ensure_tile_variant!

        ActiveRecord::Base.transaction do
          expect(doc.tile_url).not_to eq(doc.display_url)
        end
      end
    end

    # The path that actually took a Sidekiq job down: Image's
    # `before_save :update_src_url` reads doc.tile_url, and the admin board
    # builder saves Images inside one long transaction.
    it "does not render a variant when an Image is saved inside a transaction" do
      doc
      image.update_column(:src_url, nil)

      ActiveRecord::Base.transaction do
        image.reload.save!
      end

      expect(doc.tile_variant_processed?).to be(false)
      expect(image.reload.src_url).to be_present
    end
  end
end
