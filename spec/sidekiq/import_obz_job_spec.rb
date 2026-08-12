require "rails_helper"

RSpec.describe ImportObzJob do
  let(:user) { create(:user) }
  let(:obz_path) { Rails.root.join("spec/data/simple.obz") }

  # Mirrors what Api::BoardsController#import_obf persists in-request before
  # enqueueing this job: a BoardGroup in "queued" with the raw .obz attached.
  def precreate_board_group!(owner: user)
    board_group = BoardGroup.create!(name: "Imported simple.obz", user_id: owner.id, status: "queued")
    board_group.import_source_file.attach(
      io: File.open(obz_path), filename: "simple.obz", content_type: "application/zip",
    )
    board_group
  end

  it "imports the boards and marks the group complete" do
    board_group = precreate_board_group!

    expect {
      described_class.new.perform(board_group.id, user.id, {})
    }.to change { user.boards.count }.by(1)

    board_group.reload
    expect(board_group.status).to eq("complete")
    expect(board_group.root_board_id).to be_present
  end

  # Nothing else in the import path renders a snapshot, so without this the
  # imported set has no cover: BoardGroup#preview_image_url reads through to the
  # root board's attachment, and the import status page shows an empty frame.
  it "renders a preview for the imported root board" do
    board_group = precreate_board_group!

    expect {
      described_class.new.perform(board_group.id, user.id, {})
    }.to change { GenerateBoardPreviewJob.jobs.size }.by(1)

    expect(GenerateBoardPreviewJob.jobs.last["args"].first).to eq(board_group.reload.root_board_id)
  end

  # A multi-page .obz must not queue a render per page: that is one
  # headless-Chrome run per .obf on the shared :default queue, and a real
  # vocabulary set runs to 50-200 pages. Only the root — the set's cover — is
  # rendered; the rest take the folder tile that opens them.
  context "with a multi-board .obz" do
    def precreate_links_group!
      board_group = BoardGroup.create!(name: "Imported links.obz", user_id: user.id, status: "queued")
      board_group.import_source_file.attach(
        io: File.open(Rails.root.join("spec/data/links.obz")),
        filename: "links.obz", content_type: "application/zip",
      )
      board_group
    end

    it "renders exactly one preview no matter how many pages were imported" do
      board_group = precreate_links_group!

      expect {
        described_class.new.perform(board_group.id, user.id, {})
      }.to change { user.boards.count }.by(3)
        .and change { GenerateBoardPreviewJob.jobs.size }.by(1)

      expect(GenerateBoardPreviewJob.jobs.last["args"].first).to eq(board_group.reload.root_board_id)
    end

    # What apply! then DOES with those ids is covered deterministically in
    # spec/services/boards/sub_board_thumbnails_spec.rb. Asserting the outcome
    # here instead would be vacuous: no .obz fixture in spec/data has a folder
    # tile carrying artwork, so every child resolves to a blank tile image and
    # the assertion would never fire.
    it "hands every imported page to the thumbnailer, keyed on the root" do
      board_group = precreate_links_group!
      allow(Boards::SubBoardThumbnails).to receive(:apply!).and_call_original

      described_class.new.perform(board_group.id, user.id, {})

      board_group.reload
      expect(Boards::SubBoardThumbnails).to have_received(:apply!) do |args|
        expect(args[:owner]).to eq(user)
        expect(args[:root_id]).to eq(board_group.root_board_id)
        expect(args[:board_ids]).to match_array(board_group.boards.pluck(:id))
      end
    end

    # An imported page is an ordinary board — if the user edits it later and
    # earns a real rendered preview, that preview should win over the folder
    # tile. Only the Board Builder purges.
    it "does not purge previews from imported pages" do
      board_group = precreate_links_group!
      allow(Boards::SubBoardThumbnails).to receive(:apply!).and_call_original

      described_class.new.perform(board_group.id, user.id, {})

      expect(Boards::SubBoardThumbnails).to have_received(:apply!) do |args|
        expect(args[:purge_previews]).to be_falsey
      end
    end

    # A thumbnail is a nicety — it must never fail an import that otherwise
    # finished.
    it "still completes the import when thumbnailing blows up" do
      board_group = precreate_links_group!
      allow(Boards::SubBoardThumbnails).to receive(:apply!).and_raise(StandardError, "boom")

      described_class.new.perform(board_group.id, user.id, {})

      expect(board_group.reload.status).to eq("complete")
    end
  end

  it "purges the uploaded .obz once the import succeeds" do
    board_group = precreate_board_group!

    described_class.new.perform(board_group.id, user.id, {})

    expect(board_group.reload.import_source_file.attached?).to be false
  end

  it "passes import_options through to the importer (image opt-in audit)" do
    board_group = precreate_board_group!

    described_class.new.perform(
      board_group.id, user.id,
      "include_images" => true, "license_acknowledged" => true, "acknowledged_by_user_id" => user.id,
    )

    board_group.reload
    expect(board_group.settings["imported_from_obf"]).to include(
      "include_images" => true, "license_acknowledged" => true,
    )
  end

  it "marks the group failed and re-raises when the importer errors" do
    board_group = precreate_board_group!
    allow(ObzImporter).to receive(:new).and_raise(StandardError, "boom")

    expect {
      described_class.new.perform(board_group.id, user.id, {})
    }.to raise_error(StandardError, "boom")

    expect(board_group.reload.status).to eq("failed")
  end

  it "no-ops when the BoardGroup no longer exists" do
    expect { described_class.new.perform(0, user.id, {}) }.not_to raise_error
  end

  it "marks failed when the user no longer exists" do
    board_group = precreate_board_group!

    described_class.new.perform(board_group.id, 0, {})

    expect(board_group.reload.status).to eq("failed")
  end

  it "marks failed when no .obz was attached" do
    board_group = BoardGroup.create!(name: "No file", user_id: user.id, status: "queued")

    described_class.new.perform(board_group.id, user.id, {})

    expect(board_group.reload.status).to eq("failed")
  end
end
