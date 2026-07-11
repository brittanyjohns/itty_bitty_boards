# frozen_string_literal: true

require "rails_helper"

# Lifecycle is `sandbox → loaner → active` (see issue #157 / #156).
# The legacy `is_demo` boolean is kept as a derived alias during the
# frontend cutover; sandbox accounts are the only ones that are "demo".
RSpec.describe ChildAccount, "status lifecycle", type: :model do
  let(:user) { FactoryBot.create(:user) }

  it "defaults a new account to sandbox" do
    account = FactoryBot.create(:child_account, user: user)
    expect(account.status).to eq("sandbox")
    expect(account).to be_sandbox
    expect(account).to be_is_demo
  end

  it "treats sandbox as the only demo status" do
    sandbox = FactoryBot.create(:child_account, user: user, status: "sandbox")
    loaner  = FactoryBot.create(:child_account, user: user, status: "loaner")
    active  = FactoryBot.create(:child_account, user: user, status: "active")

    expect(sandbox.is_demo?).to be(true)
    expect(loaner.is_demo?).to be(false)
    expect(active.is_demo?).to be(false)
  end

  it "rejects an unknown status" do
    account = FactoryBot.build(:child_account, user: user, status: "graduated")
    expect(account).not_to be_valid
    expect(account.errors[:status]).to be_present
  end

  describe "scopes" do
    let!(:sandbox) { FactoryBot.create(:child_account, user: user, status: "sandbox") }
    let!(:loaner)  { FactoryBot.create(:child_account, user: user, status: "loaner") }
    let!(:active)  { FactoryBot.create(:child_account, user: user, status: "active") }

    it "filters by status" do
      expect(ChildAccount.sandbox).to contain_exactly(sandbox)
      expect(ChildAccount.loaner).to contain_exactly(loaner)
      expect(ChildAccount.active).to contain_exactly(active)
    end

    it "keeps the legacy demo_accounts / paid_accounts aliases for the frontend cutover" do
      expect(ChildAccount.demo_accounts).to contain_exactly(sandbox)
      expect(ChildAccount.paid_accounts).to contain_exactly(loaner, active)
    end
  end

  describe "legacy is_demo writer" do
    it "flips sandbox <-> active" do
      account = FactoryBot.create(:child_account, user: user, status: "active")
      account.is_demo = true
      expect(account.status).to eq("sandbox")
      account.is_demo = false
      expect(account.status).to eq("active")
    end

    it "does not silently demote a loaner" do
      account = FactoryBot.create(:child_account, user: user, status: "loaner")
      account.is_demo = false
      expect(account.status).to eq("loaner")
    end
  end

  describe "is_demo column sync" do
    it "keeps the legacy boolean aligned with status on save" do
      account = FactoryBot.create(:child_account, user: user, status: "sandbox")
      expect(account[:is_demo]).to be(true)

      account.update!(status: "loaner")
      expect(account[:is_demo]).to be(false)

      account.update!(status: "active")
      expect(account[:is_demo]).to be(false)
    end
  end

  describe "#api_view" do
    it "emits status alongside the derived is_demo alias" do
      account = FactoryBot.create(:child_account, user: user, status: "loaner")
      view = account.api_view(user)
      expect(view[:status]).to eq("loaner")
      expect(view[:is_demo]).to be(false)
    end
  end

  describe "#index_api_view" do
    it "emits status" do
      account = FactoryBot.create(:child_account, user: user, status: "loaner")
      expect(account.index_api_view[:status]).to eq("loaner")
    end

    it "emits the canonical public_url so dashboards match the full api_view" do
      account = FactoryBot.create(:child_account, user: user, username: "molly")
      Profile.create!(profileable: account, username: "molly", slug: "s-8bdsv4")
      account.reload

      expect(account.index_api_view[:public_url]).to eq(account.public_url)
      expect(account.index_api_view[:public_url]).to eq(account.api_view(user)[:public_url])
      expect(account.index_api_view[:public_url]).to end_with("/my/s-8bdsv4")
    end
  end
end
