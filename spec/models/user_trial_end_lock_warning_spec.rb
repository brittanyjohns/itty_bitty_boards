require "rails_helper"

# The number the day-11 warning quotes: how many boards go read-only if the
# trial lapses with no card. It must be computed against the plan the user is
# ABOUT to land on (Free), not the Basic/Pro limit they hold mid-trial —
# otherwise it is always zero right up until it is too late to act on.
RSpec.describe "User#boards_locking_at_trial_end", type: :model do
  let(:trialist) do
    create(:user, plan_type: "pro", plan_status: "trialing").tap do |u|
      u.update!(
        stripe_subscription_id: "sub_warn",
        settings: (u.settings || {}).merge("has_payment_method" => false),
      )
    end
  end

  def fresh(user) = User.find(user.id)

  it "counts everything past the slots Free would keep editable" do
    create_list(:board, 24, user: trialist)

    free_slots = [
      User.plan_limits_for("free")["board_limit"].to_i,
      User::EDITABLE_BOARD_FLOOR,
    ].max
    expect(fresh(trialist).boards_locking_at_trial_end).to eq(24 - free_slots)
  end

  it "is not zero mid-trial, even though nothing is over the CURRENT limit" do
    # The bug this method exists to avoid: Pro's limit is 300, so the user is
    # comfortably under it and a naive count reports nothing to warn about.
    create_list(:board, 24, user: trialist)
    user = fresh(trialist)

    expect(user.countable_board_count).to be < user.board_limit
    expect(user.boards_locking_at_trial_end).to be > 0
  end

  it "is zero when the set already fits Free's editable slots" do
    create_list(:board, 2, user: trialist)
    expect(fresh(trialist).boards_locking_at_trial_end).to eq(0)
  end

  it "is zero once a card is on file — the trial converts, nothing locks" do
    create_list(:board, 24, user: trialist)
    trialist.update!(settings: trialist.settings.merge("has_payment_method" => true))

    expect(fresh(trialist).boards_locking_at_trial_end).to eq(0)
  end

  it "is zero for a RevenueCat trial — they already paid through the store" do
    create_list(:board, 24, user: trialist)
    trialist.update!(stripe_subscription_id: nil)

    expect(fresh(trialist).boards_locking_at_trial_end).to eq(0)
  end

  it "is zero when there is no trial at all" do
    free = create(:free_user)
    create_list(:board, 24, user: free)

    expect(fresh(free).boards_locking_at_trial_end).to eq(0)
  end

  it "is zero for an admin — admins are never board-locked" do
    admin = create(:admin_user)
    admin.update!(
      plan_type: "pro", plan_status: "trialing",
      stripe_subscription_id: "sub_admin",
      settings: (admin.settings || {}).merge("has_payment_method" => false),
    )
    create_list(:board, 24, user: admin)

    expect(fresh(admin).boards_locking_at_trial_end).to eq(0)
  end

  it "rides along on the trial payload the client reads" do
    create_list(:board, 24, user: trialist)
    view = fresh(trialist).trial_api_view

    expect(view[:active]).to be true
    expect(view[:needs_payment_method]).to be true
    expect(view[:boards_locking]).to be > 0
  end
end
