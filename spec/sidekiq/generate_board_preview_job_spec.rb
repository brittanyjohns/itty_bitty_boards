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
    expect(board.preview_image.key).to match(%r{\Aboard_previews/#{board.id}/[^/]+/preview\.png\z})
    # The preset must point at the generated preview blob, but the exact URL
    # form depends on the configured storage backend: the Disk service yields a
    # signed /rails/active_storage/ route (CI default), while an S3/CDN-backed
    # environment (ACTIVE_STORAGE_SERVICE=amazon + CDN_HOST, as some local
    # setups use) yields a CloudFront URL built from the blob key. Accept either
    # so the test isn't coupled to a developer's local storage config.
    expect(board.settings["preset_display_image_url"]).to be_present
    expect(board.settings["preset_display_image_url"]).to match(
      %r{/rails/active_storage/|board_previews/#{board.id}/[^/]+/preview\.png},
    )
  end

  it "does not rewrite the board's display_image_url column" do
    board.update_column(:display_image_url, "https://example.com/user-cover.png")

    described_class.new.perform(board.id, "generate_png" => true)

    # The denormalized column is untouched; the live preview wins only at read
    # time (see Board#display_image_url), so the persisted seed value remains.
    expect(board.reload.read_attribute(:display_image_url)).to eq("https://example.com/user-cover.png")
  end

  it "does not rewrite display_image_url on unrelated boards that share a value" do
    shared_url = "https://example.com/shared-cover.png"
    board.update_column(:display_image_url, shared_url)
    other_user = create(:user)
    other_board = create(:board, user: other_user, display_image_url: shared_url)

    described_class.new.perform(board.id, "generate_png" => true)

    expect(other_board.reload.read_attribute(:display_image_url)).to eq(shared_url)
  end

  context "with a Board Builder sub-board" do
    it "skips PNG generation for a builder_child board" do
      board.update_column(:settings, board.settings.merge("builder_child" => true))

      described_class.new.perform(board.id, "generate_png" => true)

      board.reload
      expect(board.preview_image).not_to be_attached
      expect(board.settings).not_to have_key("preset_display_image_url")
    end

    it "records the skip so it isn't mistaken for a slow success" do
      board.update_column(:settings, board.settings.merge("builder_child" => true))

      described_class.new.perform(board.id, "generate_png" => true)

      expect(board.reload.preview_status).to eq("skipped")
    end

    # The skip is about queue volume — one render per page across a 50-200 page
    # import — not about these pages being unrenderable. An explicit,
    # single-board request passes force and renders like any other board.
    it "renders anyway when the request is forced" do
      board.update_column(:settings, board.settings.merge("builder_child" => true))

      described_class.new.perform(board.id, "generate_png" => true, "force" => true)

      board.reload
      expect(board.preview_image).to be_attached
      expect(board.preview_status).to eq("ok")
    end

    it "still generates for the builder_root board" do
      board.update_column(:settings, board.settings.merge("builder_root" => true))

      described_class.new.perform(board.id, "generate_png" => true)

      expect(board.reload.preview_image).to be_attached
    end
  end

  describe "sidekiq options" do
    it "retries on failure" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end

  describe "when retries are exhausted" do
    # Without this the render dies into the dead set while the client keeps
    # polling and is eventually told the cover "will appear shortly" — advice
    # that never comes true.
    it "marks the board's preview as failed" do
      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [board.id] },
        RuntimeError.new("grover exploded"),
      )

      expect(board.reload.preview_status).to eq("failed")
    end

    it "does not raise when the board has since been deleted" do
      missing_id = board.id
      board.destroy

      expect {
        described_class.sidekiq_retries_exhausted_block.call(
          { "args" => [missing_id] }, RuntimeError.new("grover exploded")
        )
      }.not_to raise_error
    end
  end

  describe "recording a successful render" do
    it "advances preview_generated_at and marks the status ok" do
      described_class.new.perform(board.id, "generate_png" => true)
      first_stamp = board.reload.preview_generated_at

      expect(first_stamp).to be_present
      expect(board.preview_status).to eq("ok")

      travel_to(2.minutes.from_now) do
        described_class.new.perform(board.id, "generate_png" => true)
      end

      # The stamp must advance even when the rendered PNG is byte-identical —
      # it is what the client polls on.
      expect(board.reload.preview_generated_at).to be > first_stamp
    end
  end
end
