require "rails_helper"

RSpec.describe BoardImage, "OBF formatting" do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user) }
  let(:image) { create(:image, label: "cup", user: user) }
  let!(:board_image) do
    board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
  end

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/cup.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  describe "#to_obf_image_format" do
    it "emits a url reference by default" do
      result = board_image.to_obf_image_format(user)
      expect(result[:url]).to eq("https://example.test/cup.png")
      expect(result).not_to have_key(:path)
      expect(result).not_to have_key(:data)
    end

    it "emits a zip path and no url in package mode" do
      result = board_image.to_obf_image_format(user, mode: :package, path: "images/9.png")
      expect(result[:path]).to eq("images/9.png")
      expect(result).not_to have_key(:url)
    end

    it "emits inline data and no url in inline mode" do
      result = board_image.to_obf_image_format(user, mode: :inline, data: "QUJD")
      expect(result[:data]).to eq("QUJD")
      expect(result).not_to have_key(:url)
    end

    it "falls back to a url when package mode has no path" do
      result = board_image.to_obf_image_format(user, mode: :package, path: nil)
      expect(result[:url]).to eq("https://example.test/cup.png")
    end
  end

  describe "#to_obf_button_format" do
    let(:target) { create(:board, user: user, name: "Food") }

    before { board_image.update!(predictive_board_id: target.id) }

    it "includes load_board path alongside id when given one" do
      result = board_image.to_obf_button_format(load_board_path: "boards/#{target.id}.obf")
      expect(result[:load_board][:id]).to eq(target.id.to_s)
      expect(result[:load_board][:path]).to eq("boards/#{target.id}.obf")
    end

    it "omits load_board path when none is given" do
      result = board_image.to_obf_button_format
      expect(result[:load_board]).not_to have_key(:path)
    end
  end
end
