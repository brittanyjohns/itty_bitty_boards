# frozen_string_literal: true

require "rails_helper"

# `can_edit` on a communicator payload answers "can this viewer curate boards
# on this communicator's dashboard". It used to be answered twice, differently:
# `api_view` asked the viewer, `index_api_view` asked whether the OWNER was an
# admin — so `GET /api/child_accounts` reported `can_edit: false` on a parent's
# own communicator while `GET /api/child_accounts/:id` reported `true`.
# `ChildAccount#curatable_by?` is the single answer both now read.
RSpec.describe ChildAccount, "#curatable_by?" do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end
  let!(:team) { account.ensure_team!(creator: owner) }

  it "is true for the owner" do
    expect(account.curatable_by?(owner)).to be true
  end

  it "is true for a system admin" do
    expect(account.curatable_by?(create(:admin_user))).to be true
  end

  it "is true for a team supervisor" do
    supervisor = create(:user, created_at: 2.months.ago)
    team.upsert_member!(supervisor, "supervisor")
    expect(account.curatable_by?(supervisor)).to be true
  end

  it "is false for a read-only team member" do
    member = create(:user, created_at: 2.months.ago)
    team.upsert_member!(member, "member")
    expect(account.curatable_by?(member)).to be false
  end

  it "is false for a stranger and for no viewer at all" do
    expect(account.curatable_by?(create(:user, created_at: 2.months.ago))).to be false
    expect(account.curatable_by?(nil)).to be false
  end

  describe "the serializers agree" do
    # The regression: a non-admin owner on the LIST payload. Nothing about the
    # owner's role should change the answer, and the two views must match.
    it "reports can_edit: true on both views for a non-admin owner" do
      expect(owner).not_to be_admin
      expect(account.index_api_view(owner)[:can_edit]).to be true
      expect(account.api_view(owner)[:can_edit]).to be true
    end

    it "reports can_edit: false on both views for a stranger" do
      stranger = create(:user, created_at: 2.months.ago)
      expect(account.index_api_view(stranger)[:can_edit]).to be false
      expect(account.api_view(stranger)[:can_edit]).to be false
    end

    it "reports can_edit: false on the list view with no viewer" do
      expect(account.index_api_view[:can_edit]).to be false
    end
  end
end
