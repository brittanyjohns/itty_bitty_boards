require "rails_helper"

RSpec.describe Boards::AssetRendering, type: :service do
  describe ".board_title_for" do
    it "returns the board name when present and short" do
      board = double("Board", name: "My Board")
      expect(described_class.board_title_for(board)).to eq("My Board")
    end

    it "falls back to a default when the name is blank" do
      board = double("Board", name: "")
      expect(described_class.board_title_for(board)).to eq("Communication Board")
    end

    it "falls back to a default when the name is nil" do
      board = double("Board", name: nil)
      expect(described_class.board_title_for(board)).to eq("Communication Board")
    end

    it "truncates names longer than 50 characters with an ellipsis" do
      long_name = "A" * 60
      board = double("Board", name: long_name)
      title = described_class.board_title_for(board)

      expect(title.length).to eq(50)
      expect(title).to end_with("…")
    end

    it "respects a custom max_length" do
      board = double("Board", name: "abcdefghij")
      expect(described_class.board_title_for(board, max_length: 5)).to eq("abcd…")
    end
  end
end
