require "rails_helper"

RSpec.describe Boards::PredictiveLinkSet do
  let(:user) { create(:user) }

  def link!(from_board, to_board, label: "folder")
    tile = create(:board_image, board: from_board,
                                image: create(:image, label: "#{label}-#{from_board.id}-#{to_board.id}"))
    tile.update!(predictive_board_id: to_board.id)
    tile
  end

  describe ".collect" do
    it "walks predictive links breadth-first, root first, bounded by max_depth" do
      root  = create(:board, user: user, name: "root")
      mid   = create(:board, user: user, name: "mid")
      deep  = create(:board, user: user, name: "deep")
      past  = create(:board, user: user, name: "past-cap")
      link!(root, mid)
      link!(mid, deep)
      link!(deep, past)

      collected = described_class.collect(root, max_depth: 2)
      expect(collected.first).to eq(root)
      expect(collected).to contain_exactly(root, mid, deep)
    end

    it "is cycle-safe and collects a board reachable twice only once" do
      root = create(:board, user: user, name: "root")
      sub  = create(:board, user: user, name: "sub")
      link!(root, sub)
      link!(root, sub, label: "again")
      link!(sub, root) # back-link cycle

      collected = described_class.collect(root, max_depth: 3)
      expect(collected).to contain_exactly(root, sub)
    end

    it "lets exclude veto non-root boards" do
      root = create(:board, user: user, name: "root")
      keep = create(:board, user: user, name: "keep")
      skip = create(:board, user: user, name: "skip")
      link!(root, keep)
      link!(root, skip)

      collected = described_class.collect(root, max_depth: 2,
                                                exclude: ->(b) { b.name == "skip" })
      expect(collected).to contain_exactly(root, keep)
    end
  end

  describe ".rewire!" do
    let(:source_root) { create(:board, user: user, name: "src root") }
    let(:source_sub)  { create(:board, user: user, name: "src sub") }
    let(:outside)     { create(:board, user: user, name: "outside") }

    it "translates in-set pointers to the clones and nulls out-of-set pointers with :null" do
      clone_root = create(:board, user: user, name: "clone root")
      clone_sub  = create(:board, user: user, name: "clone sub")
      in_set  = link!(clone_root, source_sub)
      out_set = link!(clone_root, outside)

      described_class.rewire!({ source_root.id => clone_root, source_sub.id => clone_sub },
                              out_of_set: :null)

      expect(in_set.reload.predictive_board_id).to eq(clone_sub.id)
      expect(out_set.reload.predictive_board_id).to be_nil
    end

    it "keeps out-of-set pointers verbatim with :keep" do
      clone_root = create(:board, user: user, name: "clone root")
      out_set = link!(clone_root, outside)

      described_class.rewire!({ source_root.id => clone_root }, out_of_set: :keep)

      expect(out_set.reload.predictive_board_id).to eq(outside.id)
    end
  end
end
