require "rails_helper"

# Pro-only extra-communicator add-on slots (settings["extra_communicator_slots"]).
# The add-on is additive to the plan's base communicator limit and flows through
# the single creation gate (Permissions::CommunicatorLimits.slot_limit_for).
RSpec.describe User, "extra communicator slots", type: :model do
  let(:user) { FactoryBot.create(:user, plan_type: "pro") }

  it "defaults to 0 extra slots" do
    expect(user.extra_communicator_slots).to eq(0)
    expect(Permissions::CommunicatorLimits.slot_limit_for(user.settings)).to eq(5)
  end

  it "adds purchased extras on top of the base plan limit" do
    user.apply_extra_communicator_slots!(3)

    expect(user.reload.extra_communicator_slots).to eq(3)
    # Base Pro limit (5) + 3 add-on slots.
    expect(Permissions::CommunicatorLimits.slot_limit_for(user.settings)).to eq(8)
    expect(user.comm_account_limit).to eq(8)
  end

  it "clamps the count to the allowed range" do
    ENV["MAX_EXTRA_COMMUNICATORS"] = "6"
    user.apply_extra_communicator_slots!(999)
    expect(user.reload.extra_communicator_slots).to eq(6)

    user.apply_extra_communicator_slots!(-1)
    expect(user.reload.extra_communicator_slots).to eq(0)
  ensure
    ENV.delete("MAX_EXTRA_COMMUNICATORS")
  end

  it "is a no-op (no save) when the count is unchanged" do
    user.apply_extra_communicator_slots!(2)
    expect(user).not_to receive(:save!)
    user.apply_extra_communicator_slots!(2)
  end

  it "is cleared on downgrade to Free (apply_free_plan)" do
    user.apply_extra_communicator_slots!(3)
    expect(user.reload.extra_communicator_slots).to eq(3)

    Billing::PlanTransitions.apply_free_plan(user, "canceled")

    expect(user.reload.extra_communicator_slots).to eq(0)
    expect(Permissions::CommunicatorLimits.slot_limit_for(user.settings)).to eq(1) # Free base only
  end

  it "raises the creation gate so an over-base communicator can be created" do
    # At the base limit (5 owned slots), the gate blocks a 6th...
    5.times { FactoryBot.create(:child_account, user: user, status: ChildAccount::ACTIVE) }
    allowed, = Permissions::CommunicatorLimits.can_create?(user: user, status: ChildAccount::ACTIVE)
    expect(allowed).to be(false)

    # ...buying 2 extras lifts the ceiling to 7.
    user.apply_extra_communicator_slots!(2)
    allowed, = Permissions::CommunicatorLimits.can_create?(user: user.reload, status: ChildAccount::ACTIVE)
    expect(allowed).to be(true)
  end
end
