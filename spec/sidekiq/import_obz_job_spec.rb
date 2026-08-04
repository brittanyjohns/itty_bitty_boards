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
