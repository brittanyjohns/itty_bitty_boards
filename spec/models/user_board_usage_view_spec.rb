# frozen_string_literal: true

require "rails_helper"

# `api_view` used to ship three board-usage numbers that could disagree inside
# one payload: `board_count` was every board the user owned (predefined ones
# included), `board_limit_reached` compared that against a locally re-read
# settings value, and `can_create_boards` used the real gate. A client reading
# the first two could be told "1 of 1, limit reached" while the server would
# happily create another board (issue #796).
RSpec.describe User, "board usage in api_view", type: :model do
  let(:user) { create(:user, settings: { "board_limit" => 10 }) }

  before do
    create(:board, user: user, name: "Standalone")
    create(:board, user: user, name: "Curated", predefined: true)

    builder_board = create(:board, user: user, name: "Built page")
    group = user.board_groups.create!(name: "Built Set", builder: true)
    group.board_group_boards.create!(board: builder_board)
  end

  it "reports the number the cap actually enforces" do
    fresh = User.find(user.id)
    view = fresh.api_view

    # Standalone + builder page; the predefined one is excluded.
    expect(view[:board_count]).to eq(2)
    expect(view[:board_count]).to eq(fresh.countable_board_count)
    expect(view[:board_limit]).to eq(fresh.board_limit)
  end

  it "keeps board_limit_reached and can_create_boards in agreement" do
    fresh = User.find(user.id)
    view = fresh.api_view

    expect(view[:board_limit_reached]).to eq(fresh.at_board_limit?)
    expect(view[:board_limit_reached]).to eq(!view[:can_create_boards])
  end

  it "agrees at the limit too" do
    user.update!(settings: user.settings.merge("board_limit" => 2))
    view = User.find(user.id).api_view

    expect(view[:board_limit_reached]).to be(true)
    expect(view[:can_create_boards]).to be(false)
  end

  # has_boards drives the dashboard empty state, so it has to keep meaning
  # "owns any board at all" — deriving it from the countable number would show
  # the empty state to a user whose only boards are predefined.
  it "reports has_boards for a user whose only board is predefined" do
    only_predefined = create(:user)
    create(:board, user: only_predefined, predefined: true)

    view = User.find(only_predefined.id).api_view
    expect(view[:board_count]).to eq(0)
    expect(view[:has_boards]).to be(true)
  end

  it "never reports limit_reached for an admin" do
    admin = create(:admin_user, settings: { "board_limit" => 1 })
    create(:board, user: admin)
    create(:board, user: admin)

    view = User.find(admin.id).api_view
    expect(view[:board_limit_reached]).to be(false)
    expect(view[:can_create_boards]).to be(true)
  end

  it "ships Board Set usage without a Board Set limit" do
    view = User.find(user.id).api_view

    expect(view[:board_group_count]).to eq(1)
    expect(view).not_to have_key(:board_group_limit)
  end

  describe "#admin_api_view" do
    it "agrees with api_view on limit, count and reached" do
      fresh = User.find(user.id)
      admin_view = fresh.admin_api_view
      view = fresh.api_view

      expect(admin_view["board_limit"]).to eq(view[:board_limit])
      expect(admin_view["board_count"]).to eq(view[:board_count])
      expect(admin_view["board_limit_reached"]).to eq(view[:board_limit_reached])
      expect(admin_view["can_create_boards"]).to eq(view[:can_create_boards])
    end

    # Without this an admin looking at the board-limit field can't tell whether
    # they're seeing a deliberate override or the plan default.
    it "says whether the limit is an override or the plan default" do
      expect(User.find(user.id).admin_api_view["board_limit_source"]).to eq("override")

      plain = create(:user, plan_type: "basic")
      expect(plain.admin_api_view["board_limit_source"]).to eq("plan")
      expect(plain.admin_api_view["board_limit"]).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
    end
  end
end
