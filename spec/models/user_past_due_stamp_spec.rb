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

  # A recovered payer must not carry a stale decline reason — the banner is
  # gone, but the reason would still be sitting in settings for the next
  # failure to be read as. Cleared in the same branch as the stamp (#826).
  it "clears the captured payment failure reason when the account leaves past_due" do
    user.update!(plan_status: "past_due")
    user.update!(settings: user.settings.merge(
      User::PAYMENT_FAILURE_KEY => { "reason" => "expired_card", "at" => Time.current.utc.iso8601 },
    ))

    user.update!(plan_status: "active")

    expect(user.reload.settings).not_to have_key(User::PAYMENT_FAILURE_KEY)
    expect(user.payment_issue_api_view).to be_nil
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
