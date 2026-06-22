require "rails_helper"

RSpec.describe Boards::PhrasesPageBuilder do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }

  describe "#call" do
    it "returns nil when no GLP function boards are seeded" do
      expect(described_class.new(communicator: communicator, owner: user).call).to be_nil
    end

    context "with seeded GLP templates" do
      before { Boards::GlpTemplates.seed!(admin: create(:admin_user)) }

      it "builds a Phrases board linking the six function sub-pages" do
        phrases_board = described_class.new(communicator: communicator, owner: user).call

        expect(phrases_board).to be_present
        expect(phrases_board.name).to eq("Phrases")
        expect(phrases_board.settings["builder_child"]).to be(true)

        function_tiles = phrases_board.board_images.select { |bi| bi.predictive_board_id.present? }
        expect(function_tiles.map(&:label)).to match_array(
          ["Greetings & Social", "Requests & Wants", "Protests & Boundaries",
           "Comments & Observations", "Feelings & Emotions", "Transitions & Routines"],
        )
      end

      it "clones the function pages with whole-phrase tiles preserved" do
        phrases_board = described_class.new(communicator: communicator, owner: user).call

        greetings_tile = phrases_board.board_images.find { |bi| bi.label == "Greetings & Social" }
        greetings = Board.find(greetings_tile.predictive_board_id)

        expect(greetings.settings["builder_child"]).to be(true)
        expect(greetings.board_images.map(&:label)).to include("hi there!", "good morning")
        expect(greetings.board_images.map { |bi| bi.image.part_of_speech }.uniq).to eq(["phrase"])
        # Cloned onto the owner, not left admin-owned.
        expect(greetings.user_id).to eq(user.id)
      end
    end
  end
end
