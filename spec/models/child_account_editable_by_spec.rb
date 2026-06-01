# frozen_string_literal: true

require "rails_helper"

# Issue #215 — helper that drives `can_edit_communicator` in api_view.
# Spec: marketing/.claude-notes/handoff-workflow.md (Permissions matrix).
RSpec.describe ChildAccount, "#editable_by?", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:supervisor) { create(:user, created_at: 2.months.ago) }
  let(:admin) { create(:admin_user) }
  let!(:account) do
    acct = create(:child_account, user: owner, owner: owner, status: "active")
    team = acct.ensure_team!(creator: owner)
    team.upsert_member!(supervisor, "supervisor")
    acct
  end

  it "is true for the owner" do
    expect(account.editable_by?(owner)).to be true
  end

  it "is true for a system admin" do
    expect(account.editable_by?(admin)).to be true
  end

  it "is false for a supervisor on the team" do
    expect(account.editable_by?(supervisor)).to be false
  end

  it "is false for nil" do
    expect(account.editable_by?(nil)).to be false
  end
end
