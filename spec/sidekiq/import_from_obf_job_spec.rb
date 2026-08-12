require "rails_helper"

RSpec.describe ImportFromObfJob do
  let(:user) { create(:user) }
  let(:board_data) { JSON.parse(File.read(Rails.root.join("spec/data/test_internal.obf"))) }

  # Mirrors what API::BoardsController#import_obf persists in-request before
  # enqueueing this job: a Board in "queued", already carrying a slug.
  def precreate_board!(owner: user)
    board = Board.new(name: board_data["name"], user: owner, status: "queued")
    board.assign_parent
    board.generate_unique_slug
    board.save!
    board
  end

  context "with a pre-created board" do
    it "fills that board in rather than creating another" do
      board = precreate_board!

      expect {
        described_class.new.perform(board_data, user.id, nil, {}, board.id)
      }.not_to change { user.boards.count }

      board.reload
      expect(board.status).to eq("complete")
      expect(board.board_images.count).to be > 0
    end

    # Same gap ImportObzJob had: the import writes tiles but renders no
    # snapshot, so the board lands on its status page with an empty cover.
    it "renders a preview for the imported board" do
      board = precreate_board!

      expect {
        described_class.new.perform(board_data, user.id, nil, {}, board.id)
      }.to change { GenerateBoardPreviewJob.jobs.size }.by(1)

      expect(GenerateBoardPreviewJob.jobs.last["args"].first).to eq(board.id)
    end

    it "marks the board failed and logs at error when the import blows up" do
      board = precreate_board!
      allow(Board).to receive(:from_obf).and_raise(StandardError, "boom")
      expect(Rails.logger).to receive(:error).at_least(:once)

      described_class.new.perform(board_data, user.id, nil, {}, board.id)

      expect(board.reload.status).to eq("failed")
    end

    it "does nothing when the board belongs to someone else" do
      board = precreate_board!(owner: create(:user))

      described_class.new.perform(board_data, user.id, nil, {}, board.id)

      expect(board.reload.status).to eq("queued")
    end
  end

  # Jobs enqueued by an older deploy carry no board_id.
  context "without a board_id" do
    it "creates the board itself" do
      expect {
        described_class.new.perform(board_data, user.id)
      }.to change { user.boards.count }.by(1)

      expect(user.boards.last.status).to eq("complete")
    end

    # `boards.slug` defaults to "" and `validates :slug, uniqueness: true`
    # does not skip blanks — a board saved without a generated slug collides
    # with the first slug-less row in the table and the import vanishes.
    it "generates a slug so an existing slug-less board can't block the save" do
      create(:board, user: create(:user), slug: "")

      expect {
        described_class.new.perform(board_data, user.id)
      }.to change { user.boards.count }.by(1)

      expect(user.boards.last.slug).to be_present
    end
  end

  it "ignores board data that isn't a board document" do
    expect {
      described_class.new.perform([1, 2, 3], user.id)
    }.not_to change { Board.count }
  end
end
