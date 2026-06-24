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
    it "attaches the preview image at a deterministic key" do
      described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      ).call(generate_png: true)

      board.reload
      expect(board.preview_image).to be_attached
      expect(board.preview_image.key).to eq("board_previews/#{board.id}/preview.png")
    end

    it "keeps the same blob key across regenerations" do
      service = described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      )

      service.call(generate_png: true)
      board.reload
      first_key = board.preview_image.key

      service.call(generate_png: true)
      board.reload
      second_key = board.preview_image.key

      expect(second_key).to eq(first_key)
      expect(second_key).to eq("board_previews/#{board.id}/preview.png")
    end

    it "refreshes the preset display image URL to the freshly generated preview" do
      described_class.new(
        board: board,
        routes: Rails.application.routes.url_helpers,
      ).call(generate_png: true)

      board.reload
      expect(board.settings["preset_display_image_url"]).to be_present
      expect(board.settings["preset_display_image_url"]).to eq(board.preview_image_url)
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
