require "rails_helper"

# Read-only boards for downgraded users: a free user over their board limit
# keeps full edit access to one designated board; the rest become read-only
# (still fully usable — view/tap/audio).
RSpec.describe "Board read-only on downgrade", type: :model do
  describe "User#board_editable?" do
    let(:user) { create(:free_user) } # board_limit 1, past trial window

    it "is true for every board when the user is under their board limit" do
      board = create(:board, user: user)
      expect(user.board_editable?(board)).to be true
    end

    context "when a free user is over their board limit" do
      let!(:board_a) { create(:board, user: user) }
      let!(:board_b) { create(:board, user: user) }

      it "allows only the designated editable board" do
        user.update!(editable_board_id: board_a.id)
        fresh = User.find(user.id)
        expect(fresh.board_editable?(board_a)).to be true
        expect(fresh.board_editable?(board_b)).to be false
      end

      it "falls back to a favorite board when none is designated" do
        board_b.update!(favorite: true)
        fresh = User.find(user.id)
        expect(fresh.board_editable?(board_b)).to be true
        expect(fresh.board_editable?(board_a)).to be false
      end
    end

    it "never locks boards for a paid user" do
      paid = create(:user, plan_type: "pro")
      expect(paid.board_editable?(create(:board, user: paid))).to be true
      expect(paid.board_editable?(create(:board, user: paid))).to be true
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
      locked = create(:board, user: user)
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
      locked = create(:board, user: user)
      user.update!(editable_board_id: designated.id)
      fresh = User.find(user.id)

      expect(locked.api_view(fresh)[:locked]).to be true
      expect(locked.api_view(fresh)[:lock_reason]).to eq("free_plan_board_limit")
      expect(designated.api_view(fresh)[:locked]).to be false
      expect(designated.api_view(fresh)[:lock_reason]).to be_nil
    end
  end
end
