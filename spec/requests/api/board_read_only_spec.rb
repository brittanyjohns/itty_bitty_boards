require "rails_helper"

# A downgraded (free) user over their board limit: the boards beyond their
# limit are read-only. They can still be viewed (usage never breaks), but
# content-mutating endpoints return HTTP 403 board_locked.
RSpec.describe "API board read-only gating", type: :request do
  let(:user) { create(:free_user) } # board_limit 1, past trial window
  let!(:editable_board) { create(:board, user: user, name: "Editable") }
  let!(:locked_board)   { create(:board, user: user, name: "Locked") }

  before { user.update!(editable_board_id: editable_board.id) }

  describe "PATCH /api/boards/:id" do
    it "returns 403 board_locked when editing a locked board" do
      patch "/api/boards/#{locked_board.id}",
            params: { board: { name: "Nope" } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("board_locked")
    end

    it "allows editing the designated board" do
      patch "/api/boards/#{editable_board.id}",
            params: { board: { name: "Renamed" } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/boards/:id on a locked board" do
    it "still serves the board so it stays usable" do
      get "/api/boards/#{locked_board.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["can_edit"]).to be false
      # The frontend keys its read-only banner off these fields, so the
      # show response (api_view_with_predictive_images) must include them
      # alongside can_edit. Regression guard for issue #155.
      expect(body["locked"]).to be true
      expect(body["lock_reason"]).to eq("free_plan_board_limit")
    end

    it "does not mark the designated editable board as locked" do
      get "/api/boards/#{editable_board.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["can_edit"]).to be true
      expect(body["locked"]).to be false
      expect(body["lock_reason"]).to be_nil
    end
  end

  describe "clinician (paid but board-limited) over their board limit" do
    let(:clinician) do
      create(:user, plan_type: "clinician").tap do |u|
        u.update!(settings: u.settings.merge("board_limit" => 1))
      end
    end
    let!(:keep) { create(:board, user: clinician, name: "Keep") }
    let!(:over) { create(:board, user: clinician, name: "Over") }

    before do
      # `keep` is the single most-recently-updated board → editable; `over` is
      # older → locked.
      keep.update_column(:updated_at, 1.hour.ago)
      over.update_column(:updated_at, 3.days.ago)
    end

    it "returns 403 board_locked when editing an over-limit board" do
      patch "/api/boards/#{over.id}",
            params: { board: { name: "Nope" } },
            headers: auth_headers(clinician)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("board_locked")
    end

    it "still serves the locked board (usage never breaks) with plan_board_limit reason" do
      get "/api/boards/#{over.id}", headers: auth_headers(clinician)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["locked"]).to be true
      expect(body["lock_reason"]).to eq("plan_board_limit")
    end

    it "allows editing a within-limit board" do
      patch "/api/boards/#{keep.id}",
            params: { board: { name: "Renamed" } },
            headers: auth_headers(clinician)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /api/boards/:id/make_editable" do
    it "moves the editable slot, locking the previous board" do
      patch "/api/boards/#{locked_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(user.reload.editable_board_id).to eq(locked_board.id)

      patch "/api/boards/#{editable_board.id}",
            params: { board: { name: "Now locked" } },
            headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects designating a board the user does not own" do
      others_board = create(:board, user: create(:user))
      patch "/api/boards/#{others_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:unauthorized)
    end

    # The endpoint used to write editable_board_id and answer 200 without
    # checking that the board actually became editable. Every pick the slot
    # rules couldn't honor came back as success with the board still locked —
    # the frontend saw no error, reloaded, and showed the same read-only
    # board. Nothing changed and nothing was reported.
    it "designates a template board the user owns" do
      template = create(:board, user: user, name: "Template", is_template: true)
      expect(template.locked_for?(user.reload)).to be true

      patch "/api/boards/#{template.id}/make_editable", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(template.locked_for?(User.find(user.id))).to be false
    end

    it "never answers ok while leaving the board locked" do
      # A board the slot rules can't hand the edit slot to: not owned by the
      # user via any association the resolver reaches.
      unreachable = create(:board, user: user, name: "Unreachable")
      allow_any_instance_of(User).to receive(:editable_board_ids).and_return([])

      patch "/api/boards/#{unreachable.id}/make_editable", headers: auth_headers(user)

      expect(response).not_to have_http_status(:ok)
      expect(JSON.parse(response.body)["error"]).to eq("editable_board_not_available")
      # The rejected pick must not consume the slot or start the cooldown.
      expect(user.reload.editable_board_id).to eq(editable_board.id)
      expect(user.editable_board_id_set_at).to be_nil
    end

    it "rejects a re-pick of the designated board when it is still locked" do
      allow_any_instance_of(User).to receive(:editable_board_ids).and_return([])

      patch "/api/boards/#{editable_board.id}/make_editable", headers: auth_headers(user)

      expect(response).not_to have_http_status(:ok)
      expect(JSON.parse(response.body)["error"]).to eq("editable_board_not_available")
    end
  end

  # A board-limited plan with more than one slot (Clinician, and any account
  # whose settings["board_limit"] was raised) resolved its editable set purely
  # by recency and ignored editable_board_id outright, so make_editable was a
  # silent no-op there.
  describe "make_editable on a plan with more than one editable slot" do
    let(:multi) do
      create(:free_user).tap { |u| u.update!(settings: u.settings.merge("board_limit" => 2)) }
    end
    let!(:recent_a) { create(:board, user: multi, name: "Recent A", updated_at: 1.minute.ago) }
    let!(:recent_b) { create(:board, user: multi, name: "Recent B", updated_at: 2.minutes.ago) }
    let!(:stale)    { create(:board, user: multi, name: "Stale", updated_at: 30.days.ago) }

    it "pins the designated board and locks the board it displaced" do
      expect(stale.locked_for?(multi.reload)).to be true

      patch "/api/boards/#{stale.id}/make_editable", headers: auth_headers(multi)

      expect(response).to have_http_status(:ok)
      fresh = User.find(multi.id)
      expect(stale.locked_for?(fresh)).to be false
      # Still only board_limit slots: the pin displaced the older of the two.
      expect(fresh.editable_board_ids.size).to eq(2)
      expect(fresh.editable_board_ids).to include(stale.id, recent_a.id)
      expect(fresh.editable_board_ids).not_to include(recent_b.id)
    end
  end

  # The cooldown closes the loophole where a free user could rotate the
  # editable slot to edit every board one at a time.
  describe "make_editable cooldown" do
    it "starts the cooldown clock on the first explicit pick (not on the auto-pin)" do
      # User starts with editable_board_id set by the let-block (auto-pin in
      # the test setup, mimicking apply_free_plan). That's not a real pick —
      # the timestamp should still be nil.
      expect(user.reload.editable_board_id_set_at).to be_nil

      patch "/api/boards/#{locked_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(user.reload.editable_board_id_set_at).not_to be_nil
    end

    it "blocks a second switch within the cooldown window" do
      user.update!(
        editable_board_id: editable_board.id,
        editable_board_id_set_at: 1.day.ago,
      )

      patch "/api/boards/#{locked_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("editable_board_cooldown")
      expect(body["cooldown_days"]).to eq(User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS)
      # The editable board did not change.
      expect(user.reload.editable_board_id).to eq(editable_board.id)
    end

    it "allows a switch once the cooldown has elapsed" do
      user.update!(
        editable_board_id: editable_board.id,
        editable_board_id_set_at: (User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS + 1).days.ago,
      )

      patch "/api/boards/#{locked_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(user.reload.editable_board_id).to eq(locked_board.id)
    end

    it "is a no-op (doesn't start the clock) when re-picking the same board" do
      patch "/api/boards/#{editable_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(user.reload.editable_board_id_set_at).to be_nil
    end

    it "lets admins bypass the cooldown" do
      admin = create(:admin_user)
      board_x = create(:board, user: admin)
      board_y = create(:board, user: admin)
      admin.update!(
        editable_board_id: board_x.id,
        editable_board_id_set_at: 1.day.ago,
      )

      patch "/api/boards/#{board_y.id}/make_editable", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(admin.reload.editable_board_id).to eq(board_y.id)
    end
  end
end
