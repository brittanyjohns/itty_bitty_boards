require "rails_helper"

# `EDITABLE_BOARD_FLOOR` decouples "how many boards may I create" (board_limit)
# from "how much of what I already made stays writable when I'm past it".
#
# They used to be the same number, which was survivable while a Free user could
# only ever be a board or two over. Once #801 made Board Builder boards count, a
# lapsed trial could land 23-35 boards over a limit of 1 — and collapsing that to
# a single editable board is a cliff.
#
# Free's own limit now EQUALS the floor (both 5), so Free alone no longer shows
# the floor doing anything. The floor scenarios below therefore pin a locked
# account to a limit BELOW the floor via the admin override, which is the case
# the floor exists for; what Free itself resolves to is asserted separately and
# derived from the constant, so moving either number never needs this file.
RSpec.describe "User editable-board floor", type: :model do
  let(:below_floor_limit) { User::EDITABLE_BOARD_FLOOR - 4 }

  def free_user_with_limit(limit)
    create(:free_user).tap do |u|
      u.update_columns(settings: (u.settings || {}).merge("board_limit" => limit))
    end
  end

  describe "#editable_slot_count" do
    it "is the floor for a limit below it" do
      user = free_user_with_limit(below_floor_limit)
      expect(user.board_limit).to be < User::EDITABLE_BOARD_FLOOR
      expect(user.editable_slot_count).to eq(User::EDITABLE_BOARD_FLOOR)
    end

    it "resolves Free to max(Free's plan limit, the floor)" do
      user = create(:free_user)
      expect(user.board_limit).to eq(User::FREE_PLAN_LIMITS["board_limit"])
      expect(user.editable_slot_count).to eq(
        [User::FREE_PLAN_LIMITS["board_limit"], User::EDITABLE_BOARD_FLOOR].max,
      )
    end

    it "is the plan's limit when that is more generous" do
      clinician = create(:user, plan_type: "clinician")
      expect(clinician.board_limit).to be > User::EDITABLE_BOARD_FLOOR
      expect(clinician.editable_slot_count).to eq(clinician.board_limit)
    end
  end

  describe "the case it exists for: a lapsed trial holding a builder set" do
    let(:user) { free_user_with_limit(below_floor_limit) }
    let!(:set) do
      Array.new(24) { |i| create(:board, user: user) }
        .each_with_index { |b, i| b.update_column(:updated_at, (30 - i).days.ago) }
    end

    it "keeps a workable set editable rather than just the board limit" do
      fresh = User.find(user.id)
      editable = set.count { |b| fresh.board_editable?(b) }
      expect(editable).to eq(User::EDITABLE_BOARD_FLOOR)
      expect(editable).to be > fresh.board_limit
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
      # make. `at_board_limit?` is untouched, so the pricing page's board count
      # is still true and the upgrade lever is still there.
      plain = create(:free_user)
      Array.new(24) { create(:board, user: plain) }

      fresh = User.find(plain.id)
      expect(fresh.at_board_limit?).to be true
      expect(fresh.board_limit).to eq(User::FREE_PLAN_LIMITS["board_limit"])
      expect(User.find(user.id).at_board_limit?).to be true
    end
  end
end
