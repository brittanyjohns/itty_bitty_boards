# == Schema Information
#
# Table name: child_boards
#
#  id                :bigint           not null, primary key
#  board_id          :bigint           not null
#  child_account_id  :bigint           not null
#  status            :string
#  settings          :jsonb
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  published         :boolean          default(FALSE)
#  favorite          :boolean          default(FALSE)
#  created_by_id     :bigint
#  original_board_id :bigint
#  layout            :jsonb
#  position          :integer
#
require 'rails_helper'

RSpec.describe ChildBoard, type: :model do
  describe "image URL fallback to original board" do
    let(:user) { create(:user) }
    let(:child_account) { create(:child_account, user: user) }

    # The template/original board carries the generated preview, mirroring how
    # public/featured boards have a display_image_url while their per-communicator
    # clones usually don't.
    let(:original_board) do
      create(:board, user: user, display_image_url: "https://cdn.example/original.png")
    end

    context "when the cloned board has no image of its own" do
      let(:cloned_board) { create(:board, user: user, display_image_url: nil) }
      let(:child_board) do
        create(:child_board, board: cloned_board, child_account: child_account,
                             original_board: original_board)
      end

      it "falls back to the original board's display_image_url" do
        expect(child_board.display_image_url).to eq("https://cdn.example/original.png")
      end

      it "exposes the fallback in api_view" do
        expect(child_board.api_view[:display_image_url]).to eq("https://cdn.example/original.png")
      end
    end

    context "when the cloned board has its own image" do
      let(:cloned_board) { create(:board, user: user, display_image_url: "https://cdn.example/clone.png") }
      let(:child_board) do
        create(:child_board, board: cloned_board, child_account: child_account,
                             original_board: original_board)
      end

      it "uses the cloned board's image and does not fall back" do
        expect(child_board.display_image_url).to eq("https://cdn.example/clone.png")
      end
    end

    context "when there is no original board" do
      let(:cloned_board) { create(:board, user: user, display_image_url: nil) }
      let(:child_board) do
        create(:child_board, board: cloned_board, child_account: child_account, original_board: nil)
      end

      it "returns nil without raising" do
        expect(child_board.display_image_url).to be_nil
      end
    end
  end
end
