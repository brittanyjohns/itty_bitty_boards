require "rails_helper"

RSpec.describe User, "past_due stamping" do
  let(:user) { create(:user, plan_type: "basic", plan_status: "active") }

  it "stamps the moment the account enters past_due" do
    expect { user.update!(plan_status: "past_due") }
      .to change { user.reload.past_due_since }.from(nil)

    expect(user.past_due_since).to be_within(1.minute).of(Time.current)
  end

  it "keeps the original stamp across later saves while still past_due" do
    user.update!(plan_status: "past_due")
    original = user.reload.past_due_since

    travel_to(2.days.from_now) do
      user.update!(name: "Renamed")
      user.update!(plan_status: "past_due")
    end

    expect(user.reload.past_due_since).to be_within(1.second).of(original)
  end

  it "clears the stamp when the account leaves past_due" do
    user.update!(plan_status: "past_due")

    expect { user.update!(plan_status: "active") }
      .to change { user.reload.past_due_since }.to(nil)
  end

  it "clears the stamp when the account is downgraded to free" do
    user.update!(plan_status: "past_due")

    Billing::PlanTransitions.apply_free_plan(user, "canceled")

    expect(user.reload.settings[User::PAST_DUE_SINCE_KEY]).to be_nil
  end

  it "reads an unparseable stamp as nil rather than as long-expired" do
    user.update!(plan_status: "past_due")
    user.update_column(:settings, user.settings.merge(User::PAST_DUE_SINCE_KEY => "not-a-date"))

    expect(user.reload.past_due_since).to be_nil
  end

  it "does not treat past_due as unpaid on its own" do
    user.update!(plan_status: "past_due")

    expect(user.paid_plan?).to be true
    expect(user.plan_stranded?).to be false
  end
end
