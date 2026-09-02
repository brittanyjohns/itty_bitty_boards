# frozen_string_literal: true

require "rails_helper"

# Consolidating a LEGACY assignment clone onto the board it was copied from.
#
# Assignment used to deep-clone a board into an invisible `is_template` copy
# that no edit to the source could ever reach. It attaches the board itself
# now, and this is the cleanup for every dashboard populated before that. It is
# unrecoverable — `boards` has no soft delete — so every check fails CLOSED: a
# clone we cannot prove is untouched keeps working exactly as it does today.
RSpec.describe Boards::AssignmentConsolidator do
  let(:owner) { create(:user, plan_type: "pro") }
  let(:communicator) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                           passcode: "ownerpw1")
  end

  # The shape assign_boards used to produce: a clone tree flagged is_template,
  # with the join row remembering the source in original_board_id.
  def legacy_assignment!(source, favorite: false)
    cloner = Boards::SetCloner.new(source, owner: owner, communicator: communicator,
                                           voice: communicator.voice, name: source.name,
                                           out_of_set: :keep)
    root_clone = cloner.call
    ids = [root_clone.id] + Board.where("settings->>'assignment_root_id' = ?", root_clone.id.to_s).pluck(:id)
    Board.where(id: ids).update_all(is_template: true)
    cb = communicator.child_boards.find_by(board_id: root_clone.id)
    cb.update_column(:favorite, true) if favorite
    [cb.reload, root_clone.reload]
  end

  let!(:source) { create(:board, user: owner, name: "Home") }

  before { create(:board_image, board: source, image: create(:image, label: "want")) }

  describe "an unedited clone" do
    it "re-points the dashboard at the source and destroys the clone" do
      child_board, clone = legacy_assignment!(source)

      result = described_class.new(child_board, dry_run: false).call

      expect(result.status).to eq(:consolidated)
      expect(child_board.reload.board_id).to eq(source.id)
      expect(child_board.original_board_id).to be_nil
      expect(Board.exists?(clone.id)).to be false
    end

    it "destroys the whole clone tree, not just its root" do
      sub = create(:board, user: owner, name: "Food")
      create(:board_image, board: sub, image: create(:image, label: "apple"))
      tile = create(:board_image, board: source, image: create(:image, label: "Food"))
      tile.update!(predictive_board_id: sub.id)

      child_board, clone = legacy_assignment!(source.reload)
      sub_clone_ids = Board.where("settings->>'assignment_root_id' = ?", clone.id.to_s).pluck(:id)
      expect(sub_clone_ids).not_to be_empty

      described_class.new(child_board, dry_run: false).call

      expect(Board.where(id: sub_clone_ids)).not_to exist
      # The owner's real sub-board is untouched.
      expect(Board.exists?(sub.id)).to be true
    end

    it "writes nothing on a dry run" do
      child_board, clone = legacy_assignment!(source)

      result = described_class.new(child_board, dry_run: true).call

      expect(result.status).to eq(:consolidated)
      expect(result.reason).to eq(:dry_run)
      expect(child_board.reload.board_id).to eq(clone.id)
      expect(Board.exists?(clone.id)).to be true
    end

    # A favorited tile is a card on the public MySpeak page, and the page gates
    # each card on the board being published — so re-pointing at an unpublished
    # source would leave a card that 404s on tap.
    it "publishes the source so a favorited MySpeak card keeps working" do
      child_board, = legacy_assignment!(source, favorite: true)
      expect(source.reload.published).to be false

      described_class.new(child_board, dry_run: false).call

      expect(source.reload.published).to be true
      expect(child_board.reload.board_id).to eq(source.id)
    end

    it "drops the redundant join when the source is already on the dashboard" do
      child_board, clone = legacy_assignment!(source)
      communicator.child_boards.create!(board: source, created_by_id: owner.id)

      described_class.new(child_board, dry_run: false).call

      expect(ChildBoard.exists?(child_board.id)).to be false
      expect(communicator.child_boards.where(board_id: source.id).count).to eq(1)
      expect(Board.exists?(clone.id)).to be false
    end
  end

  # `BoardImage#set_defaults` fills these in on the clone when the source left
  # them blank, so a LITERAL compare reported a divergence the user never made.
  # A first dry run over real data skipped 84% of clones as "edited" on the
  # strength of these four alone.
  describe "values a clone legitimately fills in are not edits" do
    it "does not read a defaulted picture as an edit when the source pinned none" do
      source.board_images.first.update_column(:display_image_url, nil)
      child_board, = legacy_assignment!(source.reload)

      expect(described_class.new(child_board, dry_run: true).call.status).to eq(:consolidated)
    end

    it "does not read a defaulted font_size as an edit" do
      source.board_images.first.update_column(:font_size, nil)
      child_board, = legacy_assignment!(source.reload)

      expect(described_class.new(child_board, dry_run: true).call.status).to eq(:consolidated)
    end

    it "does not read a defaulted display_label as an edit" do
      source.board_images.first.update_column(:display_label, nil)
      child_board, = legacy_assignment!(source.reload)

      expect(described_class.new(child_board, dry_run: true).call.status).to eq(:consolidated)
    end

    # `doc_id` lives NESTED under data["text_image"], so excepting a top-level
    # key of that name (which never exists) left every text tile diverging.
    it "does not read a stripped text-tile doc_id as an edit" do
      tile = source.board_images.first
      tile.update_column(:data, { "text_image" => { "doc_id" => 4242, "style" => "plain" } })
      child_board, clone = legacy_assignment!(source.reload)

      expect(clone.board_images.first.data.dig("text_image", "doc_id")).to be_nil
      expect(described_class.new(child_board, dry_run: true).call.status).to eq(:consolidated)
    end

    # The relaxation must not swallow the marker: "" means "this tile has no
    # picture" and never falls through to the library's art.
    it "still reads a blanked picture as an edit against a pinned source" do
      source.board_images.first.update_column(:display_image_url, "https://cdn.test/apple.png")
      child_board, clone = legacy_assignment!(source.reload)
      clone.board_images.first.update_column(:display_image_url, "")

      expect(described_class.new(child_board, dry_run: true).call.reason).to eq(:edited)
    end
  end

  describe "skips" do
    it "skips a clone whose tiles diverge from the source" do
      child_board, clone = legacy_assignment!(source)
      clone.board_images.first.update!(label: "renamed")

      result = described_class.new(child_board, dry_run: false).call

      expect(result.status).to eq(:skipped)
      expect(result.reason).to eq(:edited)
      expect(child_board.reload.board_id).to eq(clone.id)
      expect(Board.exists?(clone.id)).to be true
    end

    it "skips a clone that gained a tile the source does not have" do
      child_board, clone = legacy_assignment!(source)
      create(:board_image, board: clone, image: create(:image, label: "extra"))

      expect(described_class.new(child_board, dry_run: false).call.reason).to eq(:edited)
    end

    it "skips a clone whose picture was changed" do
      child_board, clone = legacy_assignment!(source)
      clone.board_images.first.update_column(:display_image_url, "https://cdn.test/mine.png")

      expect(described_class.new(child_board, dry_run: false).call.reason).to eq(:edited)
    end

    # `original_board_id` is a real FK with dependent: :nullify, so a deleted
    # source leaves the join pointing at nothing rather than dangling. Either
    # way the clone survives.
    it "skips when the source board is gone" do
      child_board, clone = legacy_assignment!(source)
      source.destroy

      expect(child_board.reload.original_board_id).to be_nil
      result = described_class.new(child_board, dry_run: false).call
      expect(result.reason).to eq(:source_gone)
      expect(Board.exists?(clone.id)).to be true
    end

    it "skips when the source is no longer something this owner may hold" do
      stranger = create(:user)
      child_board, clone = legacy_assignment!(source)
      source.update_column(:user_id, stranger.id)

      result = described_class.new(child_board, dry_run: false).call
      expect(result.reason).to eq(:source_not_visible)
      expect(Board.exists?(clone.id)).to be true
    end

    it "skips an ordinary attached board — there is nothing to consolidate" do
      attached = communicator.child_boards.create!(board: source, created_by_id: owner.id)

      result = described_class.new(attached, dry_run: false).call
      expect(result.reason).to eq(:not_a_legacy_clone)
    end
  end
end
