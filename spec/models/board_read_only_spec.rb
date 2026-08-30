require "rails_helper"

# Read-only boards for downgraded users: a user on a locked plan and over their
# board limit keeps full edit access to `editable_slot_count` boards — the
# designated pick plus the most recently updated — and the rest become read-only
# (still fully usable: view/tap/audio).
#
# `editable_slot_count` is `max(board_limit, EDITABLE_BOARD_FLOOR)`, so on Free
# (limit 1) the lock does not bite until the user is holding more than
# EDITABLE_BOARD_FLOOR boards. These examples create enough boards to cross it.
RSpec.describe "Board read-only on downgrade", type: :model do
  describe "User#board_editable?" do
    let(:user) { create(:free_user) } # board_limit 1, past trial window

    it "is true for every board when the user is under their board limit" do
      board = create(:board, user: user)
      expect(user.board_editable?(board)).to be true
    end

    context "when a free user is over their board limit" do
      # One more than the floor, so exactly one board is locked out. Ordered
      # oldest-first so `stalest` is the one recency drops.
      let!(:boards) do
        Array.new(User::EDITABLE_BOARD_FLOOR + 1) { create(:board, user: user) }
          .each_with_index { |b, i| b.update_column(:updated_at, (20 - i).days.ago) }
      end
      let(:stalest) { boards.first }
      let(:newest) { boards.last }

      it "keeps the designated board editable and locks what recency drops" do
        user.update!(editable_board_id: stalest.id)
        fresh = User.find(user.id)
        # The explicit pick is pinned even though it is the stalest board; the
        # slot it takes comes off the bottom of the recency list.
        expect(fresh.board_editable?(stalest)).to be true
        expect(fresh.board_editable?(newest)).to be true
        locked = boards.count { |b| !fresh.board_editable?(b) }
        expect(locked).to eq(1)
      end

      it "falls back to a favorite board when none is designated" do
        stalest.update!(favorite: true)
        fresh = User.find(user.id)
        expect(fresh.board_editable?(stalest)).to be true
      end

      it "locks nothing while at or under the floor, even though the plan allows one board" do
        # The floor is what makes Free behave like every other locked plan
        # instead of collapsing to a single editable board. Creation is still
        # capped at 1 — this only governs what stays writable.
        quiet = create(:free_user)
        few = Array.new(User::EDITABLE_BOARD_FLOOR) { create(:board, user: quiet) }
        fresh = User.find(quiet.id)
        expect(few.all? { |b| fresh.board_editable?(b) }).to be true
      end
    end

    it "never locks boards for a full paid user (Pro)" do
      paid = create(:user, plan_type: "pro")
      expect(paid.board_editable?(create(:board, user: paid))).to be true
      expect(paid.board_editable?(create(:board, user: paid))).to be true
    end

    context "when a clinician (paid but board-limited) is over their board limit" do
      # Clinician is paid_plan? true but board-limited (Basic-shaped). Use a low
      # board_limit override so the test doesn't have to create 100+ boards.
      let(:clinician) do
        create(:user, plan_type: "clinician").tap do |u|
          u.update!(settings: u.settings.merge("board_limit" => 6))
        end
      end

      it "keeps the board_limit most-recently-updated boards editable and locks the rest" do
        # board_limit 6 is above EDITABLE_BOARD_FLOOR, so the limit is what
        # binds here, not the floor. Seven boards: the stalest locks.
        filler = Array.new(4) { create(:board, user: clinician) }
        filler.each_with_index { |b, i| b.update_column(:updated_at, (5 - i).hours.ago) }
        oldest = create(:board, user: clinician)
        mid = create(:board, user: clinician)
        newest = create(:board, user: clinician)
        oldest.update_column(:updated_at, 3.days.ago)
        mid.update_column(:updated_at, 2.days.ago)
        newest.update_column(:updated_at, 1.hour.ago)

        fresh = User.find(clinician.id)
        expect(fresh.board_editable?(newest)).to be true
        expect(fresh.board_editable?(mid)).to be true
        expect(fresh.board_editable?(oldest)).to be false
      end

      it "does not lock anything while under the limit" do
        board = create(:board, user: clinician)
        expect(User.find(clinician.id).board_editable?(board)).to be true
      end

      it "reports lock_reason plan_board_limit (not free_plan_board_limit) on a locked board" do
        oldest = create(:board, user: clinician)
        Array.new(6) { create(:board, user: clinician) }
        oldest.update_column(:updated_at, 5.days.ago)

        view = oldest.api_view(User.find(clinician.id))
        expect(view[:locked]).to be true
        expect(view[:lock_reason]).to eq("plan_board_limit")
      end
    end

    it "never locks boards for an admin" do
      admin = create(:admin_user)
      create(:board, user: admin)
      expect(admin.board_editable?(create(:board, user: admin))).to be true
    end

    it "does not gate boards the user does not own" do
      others_board = create(:board, user: create(:user))
      create(:board, user: user)
      create(:board, user: user)
      expect(user.board_editable?(others_board)).to be true
    end
  end

  describe "User#effective_editable_board_id" do
    let(:user) { create(:free_user) }

    it "returns the designated board when it still belongs to the user" do
      board = create(:board, user: user)
      user.update!(editable_board_id: board.id)
      expect(User.find(user.id).effective_editable_board_id).to eq(board.id)
    end

    it "falls back to the most-recently-updated board when none is designated" do
      old = create(:board, user: user)
      recent = create(:board, user: user)
      old.update_column(:updated_at, 2.days.ago)
      recent.update_column(:updated_at, 1.hour.ago)
      expect(user.effective_editable_board_id).to eq(recent.id)
    end

    it "prefers a favorite board over a more recent non-favorite" do
      fav = create(:board, user: user, favorite: true)
      recent = create(:board, user: user)
      fav.update_column(:updated_at, 2.days.ago)
      recent.update_column(:updated_at, 1.hour.ago)
      expect(user.effective_editable_board_id).to eq(fav.id)
    end
  end

  describe "editable-board switch cooldown" do
    let(:user) { create(:free_user) }
    let!(:board_a) { create(:board, user: user) }
    let!(:board_b) { create(:board, user: user) }

    it "is inactive while editable_board_id_set_at is nil" do
      expect(user.editable_board_switch_available_at).to be_nil
      expect(user.editable_board_switch_cooldown_active?).to be false
    end

    it "is active during the cooldown window after an explicit pick" do
      user.update!(
        editable_board_id: board_a.id,
        editable_board_id_set_at: 3.days.ago,
      )
      fresh = User.find(user.id)
      expect(fresh.editable_board_switch_cooldown_active?).to be true
      expect(fresh.editable_board_switch_available_at).to be_within(5.seconds).of(
        3.days.ago + User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS.days,
      )
    end

    it "is inactive once the cooldown has elapsed" do
      user.update!(
        editable_board_id: board_a.id,
        editable_board_id_set_at: (User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS + 1).days.ago,
      )
      fresh = User.find(user.id)
      expect(fresh.editable_board_switch_cooldown_active?).to be false
    end

    it "pin_default_editable_board! does NOT start the cooldown clock" do
      user.pin_default_editable_board!
      fresh = User.find(user.id)
      expect(fresh.editable_board_id).not_to be_nil
      expect(fresh.editable_board_id_set_at).to be_nil
      expect(fresh.editable_board_switch_cooldown_active?).to be false
    end
  end

  describe "Board#can_edit_for" do
    it "is false on a locked board and true on the designated board" do
      user = create(:free_user)
      designated = create(:board, user: user)
      Array.new(User::EDITABLE_BOARD_FLOOR) { create(:board, user: user) }
      locked = create(:board, user: user)
      locked.update_column(:updated_at, 9.days.ago)
      user.update!(editable_board_id: designated.id)
      fresh = User.find(user.id)
      expect(designated.can_edit_for(fresh)).to be true
      expect(locked.can_edit_for(fresh)).to be false
    end
  end

  describe "Board#api_view locked fields" do
    it "marks an over-limit non-designated board as locked" do
      user = create(:free_user)
      designated = create(:board, user: user)
      Array.new(User::EDITABLE_BOARD_FLOOR) { create(:board, user: user) }
      locked = create(:board, user: user)
      locked.update_column(:updated_at, 9.days.ago)
      user.update!(editable_board_id: designated.id)
      fresh = User.find(user.id)

      expect(locked.api_view(fresh)[:locked]).to be true
      expect(locked.api_view(fresh)[:lock_reason]).to eq("free_plan_board_limit")
      expect(designated.api_view(fresh)[:locked]).to be false
      expect(designated.api_view(fresh)[:lock_reason]).to be_nil
    end
  end
end
