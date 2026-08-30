require "rails_helper"

# `EDITABLE_BOARD_FLOOR` decouples "how many boards may I create" (board_limit)
# from "how much of what I already made stays writable when I'm past it".
#
# They used to be the same number, which was survivable while a Free user could
# only ever be a board or two over. Once #801 made Board Builder boards count, a
# lapsed trial could land 23-35 boards over a limit of 1 — and collapsing that to
# a single editable board is a cliff.
RSpec.describe "User editable-board floor", type: :model do
  describe "#editable_slot_count" do
    it "is the floor for a plan whose limit is below it" do
      user = create(:free_user)
      expect(user.board_limit).to eq(1)
      expect(user.editable_slot_count).to eq(User::EDITABLE_BOARD_FLOOR)
    end

    it "is the plan's limit when that is more generous" do
      clinician = create(:user, plan_type: "clinician")
      expect(clinician.board_limit).to be > User::EDITABLE_BOARD_FLOOR
      expect(clinician.editable_slot_count).to eq(clinician.board_limit)
    end
  end

  describe "the case it exists for: a lapsed trial holding a builder set" do
    let(:user) { create(:free_user) }
    let!(:set) do
      Array.new(24) { |i| create(:board, user: user) }
        .each_with_index { |b, i| b.update_column(:updated_at, (30 - i).days.ago) }
    end

    it "keeps a workable set editable rather than exactly one board" do
      fresh = User.find(user.id)
      editable = set.count { |b| fresh.board_editable?(b) }
      expect(editable).to eq(User::EDITABLE_BOARD_FLOOR)
      expect(editable).to be > 1
    end

    it "still locks the rest — the floor softens the cliff, it does not remove it" do
      fresh = User.find(user.id)
      expect(set.count { |b| !fresh.board_editable?(b) }).to eq(
        set.size - User::EDITABLE_BOARD_FLOOR,
      )
    end

    it "never breaks AAC usage: every board stays readable" do
      fresh = User.find(user.id)
      expect(set.all? { |b| b.api_view(fresh)[:id].present? }).to be true
    end

    it "grants no new boards — creation is still capped by the plan" do
      # The whole point: this changes what stays writable, not what you may
      # make. `at_board_limit?` is untouched, so the pricing page's "1 board"
      # is still true and the upgrade lever is still there.
      expect(User.find(user.id).at_board_limit?).to be true
      expect(User.find(user.id).board_limit).to eq(1)
    end
  end
end
