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

    it "caps the walk at max_boards" do
      root = create(:board, user: user, name: "root")
      subs = 4.times.map { |i| create(:board, user: user, name: "sub-#{i}") }
      subs.each { |sub| link!(root, sub) }

      collected = described_class.collect(root, max_depth: 3, max_boards: 3)

      expect(collected.size).to eq(3)
      expect(collected.first).to eq(root)
      expect(collected).to all(satisfy { |b| [root, *subs].include?(b) })
    end

    # Depth does not bound a WIDE graph — one board with 200 folder tiles is
    # depth 1 — and every caller hydrates the result, so the count cap is the
    # only thing standing between a pathological set and the whole table.
    it "caps a shallow but wide graph that max_depth alone would not bound" do
      root = create(:board, user: user, name: "root")
      12.times { |i| link!(root, create(:board, user: user, name: "wide-#{i}")) }

      expect(described_class.collect(root, max_depth: 1, max_boards: 5).size).to eq(5)
      expect(described_class.collect(root, max_depth: 1).size).to eq(13)
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

    describe "out_of_set: :flatten" do
      it "turns an out-of-set folder tile into an ordinary speaking tile" do
        clone_root = create(:board, user: user, name: "clone root")
        clone_sub  = create(:board, user: user, name: "clone sub")
        in_set  = link!(clone_root, source_sub)
        out_set = link!(clone_root, outside)
        out_set.update!(data: (out_set.data || {}).merge("mute_name" => true))

        described_class.rewire!({ source_root.id => clone_root, source_sub.id => clone_sub },
                                out_of_set: :flatten)

        expect(in_set.reload.predictive_board_id).to eq(clone_sub.id)
        expect(out_set.reload.predictive_board_id).to be_nil
      end

      # Nulling the column alone leaves a muted tile with nowhere to go —
      # door_tile? is true on mute_name by itself — which is worse than the
      # broken link it replaced.
      it "clears the navigation markers, not just the pointer" do
        clone_root = create(:board, user: user, name: "clone root")
        out_set = link!(clone_root, outside)
        out_set.update!(data: (out_set.data || {}).merge("mute_name" => true))

        described_class.rewire!({ source_root.id => clone_root }, out_of_set: :flatten)

        expect(out_set.reload.data["mute_name"]).to be_nil
        expect(out_set.reload.door_tile?).to be(false)
      end

      it "flattens a pointer whose target board no longer exists" do
        clone_root = create(:board, user: user, name: "clone root")
        dangling = link!(clone_root, outside)
        outside.delete # bypass dependent: :nullify so the tile keeps the id

        described_class.rewire!({ source_root.id => clone_root }, out_of_set: :flatten)

        expect(dangling.reload.predictive_board_id).to be_nil
      end
    end

    it "returns how many out-of-set pointers it acted on" do
      clone_root = create(:board, user: user, name: "clone root")
      clone_sub  = create(:board, user: user, name: "clone sub")
      link!(clone_root, source_sub)
      link!(clone_root, outside)
      link!(clone_root, outside, label: "second")
      map = { source_root.id => clone_root, source_sub.id => clone_sub }

      expect(described_class.rewire!(map.dup, out_of_set: :flatten)).to eq(2)
    end

    it "reports zero under :keep, which acts on nothing" do
      clone_root = create(:board, user: user, name: "clone root")
      link!(clone_root, outside)

      expect(described_class.rewire!({ source_root.id => clone_root }, out_of_set: :keep)).to eq(0)
    end
  end
end
