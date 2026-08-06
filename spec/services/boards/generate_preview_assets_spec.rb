require "rails_helper"

RSpec.describe Boards::GeneratePreviewAssets, type: :service do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Preview Test") }

  before do
    fake_grover = instance_double(Grover, to_png: "\x89PNG\r\n\x1a\n-fake-png-bytes")
    allow(Grover).to receive(:new).and_return(fake_grover)

    allow(ApplicationController).to receive(:render).and_return("<html></html>")
    allow(Boards::RenderAssetData).to receive(:new).and_return(
      double("RenderAssetData", call: { landscape: false }),
    )
  end

  describe "#call(generate_png: true)" do
    it "attaches the preview image under the board's preview namespace" do
      described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      ).call(generate_png: true)

      board.reload
      expect(board.preview_image).to be_attached
      expect(board.preview_image.key).to match(%r{\Aboard_previews/#{board.id}/[^/]+/preview\.png\z})
    end

    # The CDN in front of the bucket does not include the query string in its
    # cache key, so a `?v=` buster on a fixed key never invalidates anything —
    # covers silently stopped updating after the first regeneration. A distinct
    # PATH per generation is the only reliable invalidation. Do not "simplify"
    # this back to one stable key.
    it "gives every regeneration its own key so the CDN can't serve a stale PNG" do
      service = described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      )

      service.call(generate_png: true)
      first_key = board.reload.preview_image.key

      service.call(generate_png: true)
      second_key = board.reload.preview_image.key

      expect(second_key).not_to eq(first_key)
      expect(second_key).to start_with("board_previews/#{board.id}/")
    end

    it "purges the superseded object so old previews don't accumulate" do
      service = described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      )

      service.call(generate_png: true)
      first_blob = board.reload.preview_image.blob

      service.call(generate_png: true)

      expect(ActiveStorage::Blob.where(id: first_blob.id)).to be_empty
      expect(board.preview_image.service.exist?(first_blob.key)).to be(false)
    end

    it "refreshes the preset display image URL to the freshly generated preview" do
      # Wrap both the generation (which stores the URL) and the assertion's
      # re-read in one frozen instant: on the Disk backend (CI) preview_image_url
      # is a signed URL whose token embeds Time.current, so two reads a
      # millisecond apart differ. An S3/CDN backend yields a stable URL either
      # way; freezing keeps the test backend-agnostic.
      freeze_time do
        described_class.new(
          board: board,
          routes: Rails.application.routes.url_helpers,
        ).call(generate_png: true)

        board.reload
        expect(board.settings["preset_display_image_url"]).to be_present
        expect(board.settings["preset_display_image_url"]).to eq(board.preview_image_url)
      end
    end

    it "creates a fresh blob row each regeneration so created_at advances" do
      service = described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      )

      service.call(generate_png: true)
      first_updated_at = board.reload.preview_image.blob.created_at

      travel(1.second) do
        service.call(generate_png: true)
      end

      second_updated_at = board.reload.preview_image.blob.created_at
      expect(second_updated_at).to be > first_updated_at
    end
  end
end
