require "rails_helper"

RSpec.describe GenerateBoardPreviewJob, type: :job do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Job Preview") }

  before do
    fake_grover = instance_double(Grover, to_png: "\x89PNG\r\n\x1a\n-fake-png-bytes")
    allow(Grover).to receive(:new).and_return(fake_grover)

    allow(ApplicationController).to receive(:render).and_return("<html></html>")
    allow(Boards::RenderAssetData).to receive(:new).and_return(
      double("RenderAssetData", call: { landscape: false }),
    )
  end

  it "attaches the preview image and writes the preset display image url" do
    described_class.new.perform(board.id, "generate_png" => true)

    board.reload
    expect(board.preview_image).to be_attached
    expect(board.preview_image.key).to eq("board_previews/#{board.id}/preview.png")
    # The preset must point at the generated preview blob, but the exact URL
    # form depends on the configured storage backend: the Disk service yields a
    # signed /rails/active_storage/ route (CI default), while an S3/CDN-backed
    # environment (ACTIVE_STORAGE_SERVICE=amazon + CDN_HOST, as some local
    # setups use) yields a CloudFront URL built from the blob key. Accept either
    # so the test isn't coupled to a developer's local storage config.
    expect(board.settings["preset_display_image_url"]).to be_present
    expect(board.settings["preset_display_image_url"]).to match(
      %r{/rails/active_storage/|board_previews/#{board.id}/preview\.png},
    )
  end

  it "does not modify the board's display_image_url" do
    board.update_column(:display_image_url, "https://example.com/user-cover.png")

    described_class.new.perform(board.id, "generate_png" => true)

    expect(board.reload.display_image_url).to eq("https://example.com/user-cover.png")
  end

  it "does not rewrite display_image_url on unrelated boards that share a value" do
    shared_url = "https://example.com/shared-cover.png"
    board.update_column(:display_image_url, shared_url)
    other_user = create(:user)
    other_board = create(:board, user: other_user, display_image_url: shared_url)

    described_class.new.perform(board.id, "generate_png" => true)

    expect(other_board.reload.display_image_url).to eq(shared_url)
  end

  describe "sidekiq options" do
    it "retries on failure" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end
end
