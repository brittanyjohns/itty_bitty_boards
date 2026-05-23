# frozen_string_literal: true

require "rails_helper"

RSpec.describe Permissions::CommunicatorLimits do
  # Slot math after the loaner-lifecycle rework (issue #158):
  #   Free  — 0 self-created; may host 1 claimed; +1 sandbox.
  #   Basic — 2 self-created.
  #   Pro   — 3 self-created, loaner-capable.

  describe ".can_create?" do
    context "free user requesting a sandbox communicator" do
      # created_at outside the soft-trial window so the user stays on `free`.
      let(:user) { create(:user, created_at: 2.months.ago) }

      before { user.setup_free_limits; user.save! }

      it "allows the first sandbox communicator (the MySpeak ID)" do
        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::SANDBOX)

        expect(allowed).to be(true)
        expect(http_status).to eq(:ok)
        expect(error).to be_nil
      end

      it "blocks a second sandbox once the slot is used" do
        create(:child_account, user: user, owner: user, status: ChildAccount::SANDBOX)

        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::SANDBOX)

        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_entity)
        expect(error).to match(/limit reached/i)
      end

      it "blocks self-creating an active communicator (Free can't self-create)" do
        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)

        expect(allowed).to be(false)
        expect(http_status).to eq(:forbidden)
        expect(error).to match(/does not allow|does not include/i)
      end

      it "still accepts the legacy is_demo:true shape" do
        allowed, http_status, _error = described_class.can_create?(user: user, is_demo: true)
        expect(allowed).to be(true)
        expect(http_status).to eq(:ok)
      end
    end

    context "basic user" do
      let(:user) { create(:user, plan_type: "basic", created_at: 2.months.ago) }

      it "allows up to two self-created communicators" do
        2.times { create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE) }

        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)

        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_entity)
        expect(error).to match(/maximum.*reached/i)
      end

      it "allows the second one before the cap" do
        create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)

        allowed, http_status, _error = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)
        expect(allowed).to be(true)
        expect(http_status).to eq(:ok)
      end

      it "counts loaners against the same slot pool as active" do
        create(:child_account, user: user, owner: user, status: ChildAccount::LOANER)
        create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)

        allowed, http_status, _error = described_class.can_create?(user: user, status: ChildAccount::LOANER)
        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_entity)
      end
    end

    context "pro user" do
      let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

      it "allows up to three self-created communicators" do
        3.times { create(:child_account, user: user, owner: user, status: ChildAccount::LOANER) }

        allowed, http_status, _error = described_class.can_create?(user: user, status: ChildAccount::LOANER)
        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_entity)
      end
    end
  end

  describe ".can_claim?" do
    let(:user) { create(:user, created_at: 2.months.ago) }

    before { user.setup_free_limits; user.save! }

    it "lets a free user host one claimed communicator" do
      allowed, http_status, _error = described_class.can_claim?(user: user)
      expect(allowed).to be(true)
      expect(http_status).to eq(:ok)
    end

    it "blocks a second claimed communicator once the free slot is used" do
      create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)

      allowed, http_status, error = described_class.can_claim?(user: user)
      expect(allowed).to be(false)
      expect(http_status).to eq(:unprocessable_entity)
      expect(error).to match(/maximum/i)
    end
  end
end
