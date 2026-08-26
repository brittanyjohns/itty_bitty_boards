require "rails_helper"

RSpec.describe ImageMergeJob do
  # This job destroys Image rows and `images` has no soft-delete, so every
  # example here is about something that must SURVIVE a merge, or something the
  # job must refuse to touch.
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def library_image(label, **attrs)
    create(:image, label: label, user_id: nil, is_private: false, **attrs)
  end

  # Build a batch straight from the scanner so the plan under test is exactly
  # the plan the operator would have reviewed.
  def batch_for(label, status: "running")
    plan = Images::DuplicateScanner.call(label: label)
    ImageMergeBatch.create!(status: status, plan: { "groups" => plan["groups"] }, report: plan["report"])
  end

  describe "the happy path" do
    let!(:rich) { library_image("wagon") }
    let!(:sparse) { library_image("wagon") }
    let!(:rich_doc) { create(:doc, documentable: rich, user_id: nil) }
    let!(:sparse_doc) { create(:doc, documentable: sparse, user_id: nil) }
    let!(:batch) { batch_for("wagon") }

    it "moves the loser's docs onto the survivor and destroys only the loser" do
      expect { described_class.new.perform(batch.id, 0) }.to change(Image, :count).by(-1)

      expect(Image.find_by(id: sparse.id)).to be_nil
      expect(rich.reload.docs.pluck(:id)).to match_array([rich_doc.id, sparse_doc.id])
    end

    it "keeps every doc — merging consolidates art, it never deletes it" do
      expect { described_class.new.perform(batch.id, 0) }.not_to change(Doc, :count)
    end

    it "records a ledger row with a snapshot of what it destroyed" do
      described_class.new.perform(batch.id, 0)

      merge = batch.image_merges.sole
      expect(merge.status).to eq("merged")
      expect(merge.survivor_id).to eq(rich.id)
      expect(merge.doc_ids).to include(sparse_doc.id)
      expect(merge.merged_attributes["images"].first["id"]).to eq(sparse.id)
    end

    it "completes the batch once every group has been handled" do
      described_class.new.perform(batch.id, 0)
      expect(batch.reload).to be_complete
    end
  end

  describe "things that must survive the merge" do
    let!(:user) { create(:user) }
    let!(:rich) { library_image("kite") }
    let!(:sparse) { library_image("kite") }
    let!(:rich_doc) { create(:doc, documentable: rich, user_id: nil) }

    it "reparents predictive boards instead of letting dependent: :destroy take them" do
      predictive = create(:board, user: user, parent: sparse, parent_type: "Image")
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(Board.find_by(id: predictive.id)).to be_present
      expect(predictive.reload.parent_id).to eq(rich.id)
      expect(predictive.parent_type).to eq("Image")
    end

    it "repoints a user's saved picture choice so it does not silently detach" do
      doomed_doc = create(:doc, documentable: sparse, user_id: nil)
      user_doc = UserDoc.create!(user: user, doc: doomed_doc, image_id: sparse.id)
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(user_doc.reload.image_id).to eq(rich.id)
      expect(rich.reload.display_doc(user)).to eq(doomed_doc)
    end

    it "moves a board tile to the survivor while leaving its own picture untouched" do
      board = create(:board, user: user)
      tile = create(:board_image, board: board, image: sparse)
      tile.update_column(:display_image_url, "https://cdn.example.com/mine.webp")
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(tile.reload.image_id).to eq(rich.id)
      expect(tile.display_image_url).to eq("https://cdn.example.com/mine.webp")
    end

    it "preserves the blank hide-pictures marker rather than repainting the tile" do
      board = create(:board, user: user)
      tile = create(:board_image, board: board, image: sparse)
      tile.update_column(:display_image_url, "")
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(tile.reload.display_image_url).to eq("")
      expect(tile).to be_picture_hidden
    end

    it "moves a soft-deleted doc too, instead of orphaning it" do
      hidden = create(:doc, documentable: sparse, user_id: nil)
      hidden.hide!
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(Doc.unscoped.find(hidden.id).documentable_id).to eq(rich.id)
    end

    # docs.current is the LIBRARY DEFAULT and is meant to be single-valued per
    # image. Merging two images that each carried their own default left the
    # survivor with both, so Image#display_doc resolved an arbitrary one.
    it "leaves the survivor with exactly one library default" do
      create(:doc, documentable: rich, user_id: nil, current: true)
      create(:doc, documentable: sparse, user_id: nil, current: true)
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(rich.reload.docs.where(current: true).count).to eq(1)
    end

    it "keeps the survivor's own default rather than an inherited one" do
      keeper = create(:doc, documentable: rich, user_id: nil, current: true)
      create(:doc, documentable: sparse, user_id: nil, current: true)
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(rich.reload.docs.where(current: true).pluck(:id)).to eq([keeper.id])
    end

    it "does not invent a default for a group that never had one" do
      create(:doc, documentable: sparse, user_id: nil)
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(rich.reload.docs.where(current: true)).to be_empty
    end

    it "keeps the union of next_words" do
      sparse.update_columns(next_words: %w[string fly])
      rich.update_columns(next_words: %w[string])
      batch = batch_for("kite")

      described_class.new.perform(batch.id, 0)

      expect(rich.reload.next_words).to match_array(%w[string fly])
    end
  end

  describe "refusing to act on stale or out-of-scope rows" do
    let!(:rich) { library_image("balloon") }
    let!(:sparse) { library_image("balloon") }

    it "skips a loser that has been relabelled since the scan" do
      batch = batch_for("balloon")
      sparse.update!(label: "something else")

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges.sole.status).to eq("skipped")
    end

    it "skips a loser that has become a user's image since the scan" do
      batch = batch_for("balloon")
      sparse.update!(user_id: create(:user).id)

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges.sole.status).to eq("skipped")
    end

    it "skips a loser that has been made private since the scan" do
      batch = batch_for("balloon")
      sparse.update!(is_private: true)

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges.sole.status).to eq("skipped")
    end

    it "does nothing when the survivor itself has drifted" do
      batch = batch_for("balloon")
      rich.update!(part_of_speech: "verb")

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges.sole.skip_reason).to match(/survivor/)
    end
  end

  describe "the kill switch and replays" do
    let!(:rich) { library_image("puddle") }
    let!(:sparse) { library_image("puddle") }

    it "does nothing at all while the batch is paused" do
      batch = batch_for("puddle", status: "paused")

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges).to be_empty
    end

    it "does nothing for a batch that was never applied" do
      batch = batch_for("puddle", status: "planned")

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
    end

    it "is a no-op when replayed" do
      batch = batch_for("puddle")
      described_class.new.perform(batch.id, 0)

      expect { described_class.new.perform(batch.id, 0) }.not_to change(Image, :count)
      expect(batch.image_merges.count).to eq(1)
    end
  end
end
