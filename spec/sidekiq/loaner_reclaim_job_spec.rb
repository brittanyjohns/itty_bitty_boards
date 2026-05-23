# frozen_string_literal: true

require "rails_helper"

# Issue #161 (B5) — 90-day auto-reclaim.
RSpec.describe LoanerReclaimJob, type: :job do
  let(:slp) { create(:user, plan_type: "pro", created_at: 6.months.ago) }

  def loaner_with(claim_token_sent_at: nil, loaner_started_at: nil, status: "loaner", claimed_at: nil)
    create(:child_account,
           user: slp, owner: slp,
           status: status, passcode: "x#{SecureRandom.hex(2)}",
           username: "loan-#{SecureRandom.hex(3)}",
           claim_token_sent_at: claim_token_sent_at,
           loaner_started_at: loaner_started_at,
           claimed_at: claimed_at)
  end

  it "reclaims a loaner whose claim link was sent over 90 days ago" do
    stale = loaner_with(claim_token_sent_at: 95.days.ago)

    described_class.new.perform

    expect(stale.reload.status).to eq("sandbox")
    expect(stale.passcode).to be_nil
  end

  it "leaves a loaner inside the 90-day window alone" do
    fresh = loaner_with(claim_token_sent_at: 30.days.ago)

    described_class.new.perform

    expect(fresh.reload.status).to eq("loaner")
  end

  it "falls back to loaner_started_at when no claim link was sent" do
    stale = loaner_with(claim_token_sent_at: nil, loaner_started_at: 100.days.ago)

    described_class.new.perform

    expect(stale.reload.status).to eq("sandbox")
  end

  it "doesn't touch claimed (active) accounts" do
    parent = create(:user)
    active = create(:child_account, user: parent, owner: parent, status: "active",
                                    passcode: "p", username: "active-#{SecureRandom.hex(2)}",
                                    claimed_at: 200.days.ago)

    described_class.new.perform

    expect(active.reload.status).to eq("active")
  end

  it "frees the SLP's slot on reclaim" do
    loaner_with(claim_token_sent_at: 95.days.ago)
    expect {
      described_class.new.perform
    }.to change { slp.communicator_accounts.where(status: ["loaner", "active"]).count }.from(1).to(0)
  end
end
