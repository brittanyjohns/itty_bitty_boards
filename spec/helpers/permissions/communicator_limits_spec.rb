# frozen_string_literal: true

require "rails_helper"

RSpec.describe Permissions::CommunicatorLimits do
  # Slot math:
  #   Free  — 1 full communicator, CLAIM/HAND-OFF ONLY; +1 sandbox self-create.
  #           (`can_create?` reports the active slot as available capacity, but a
  #           self-create is coerced to sandbox by `.self_create_status`.)
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
        expect(http_status).to eq(:unprocessable_content)
        expect(error).to match(/limit reached/i)
      end

      it "reports the active slot as available capacity (the slot a claim fills)" do
        # `can_create?` is a pure capacity check — the Free user has 1 active
        # slot. Whether a *self-create* may take it is the separate policy in
        # `.self_create_status` (it can't: self-creates are coerced to sandbox).
        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)

        expect(allowed).to be(true)
        expect(http_status).to eq(:ok)
        expect(error).to be_nil
      end

      it "blocks a second active once the free slot is used" do
        create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)

        allowed, http_status, error = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)

        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_content)
        expect(error).to match(/maximum.*reached/i)
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
        expect(http_status).to eq(:unprocessable_content)
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
        expect(http_status).to eq(:unprocessable_content)
      end
    end

    context "pro user" do
      let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

      it "allows up to five self-created communicators" do
        5.times { create(:child_account, user: user, owner: user, status: ChildAccount::LOANER) }

        allowed, http_status, _error = described_class.can_create?(user: user, status: ChildAccount::LOANER)
        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_content)
      end

      it "allows sandbox communicators up to the Pro limit, then blocks" do
        limit = User::PRO_PLAN_LIMITS["demo_communicator_limit"]
        limit.times { create(:child_account, user: user, owner: user, status: ChildAccount::SANDBOX) }

        allowed, http_status, _error = described_class.can_create?(user: user, status: ChildAccount::SANDBOX)
        expect(allowed).to be(false)
        expect(http_status).to eq(:unprocessable_content)
      end
    end
  end

  describe ".self_create_status" do
    it "forces a Free user's self-create to sandbox, whatever was requested" do
      user = create(:user, created_at: 2.months.ago)
      user.setup_free_limits
      user.save!

      expect(
        described_class.self_create_status(user: user, requested: ChildAccount::ACTIVE),
      ).to eq(ChildAccount::SANDBOX)
      expect(
        described_class.self_create_status(user: user, requested: ChildAccount::LOANER),
      ).to eq(ChildAccount::SANDBOX)
      expect(
        described_class.self_create_status(user: user, requested: ChildAccount::SANDBOX),
      ).to eq(ChildAccount::SANDBOX)
    end

    it "leaves a paid user's requested status untouched" do
      basic = create(:user, plan_type: "basic", created_at: 2.months.ago)
      pro = create(:user, plan_type: "pro", created_at: 2.months.ago)

      expect(
        described_class.self_create_status(user: basic, requested: ChildAccount::ACTIVE),
      ).to eq(ChildAccount::ACTIVE)
      expect(
        described_class.self_create_status(user: pro, requested: ChildAccount::ACTIVE),
      ).to eq(ChildAccount::ACTIVE)
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
      expect(http_status).to eq(:unprocessable_content)
      expect(error).to match(/maximum/i)
    end
  end
  describe ".slots_for" do
    let(:user) do
      u = create(:user, plan_type: "clinician", created_at: 2.months.ago)
      u.setup_clinician_limits
      u.save!
      u
    end

    it "counts a loaner and an active against the same slot budget" do
      create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)
      create(:child_account, user: user, owner: user, status: ChildAccount::LOANER)
      # Sandboxes have their own quota and never occupy a slot.
      create(:child_account, user: user, owner: user, status: ChildAccount::SANDBOX)

      expect(described_class.slots_for(user: user)).to eq(
        limit: 2, used: 2, available: 0, on_loan: 1, active: 1, limit_reached: true,
      )
    end

    it "agrees with can_create?, which is the point of it existing" do
      2.times { create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE) }

      allowed, _status, _error, code = described_class.can_create?(user: user, status: ChildAccount::ACTIVE)
      expect(described_class.slots_for(user: user)[:limit_reached]).to eq(!allowed)
      expect(code).to eq(described_class::SLOT_LIMIT_REACHED)
    end

    it "reads the communicator_slot_limit override the gate enforces" do
      user.update!(settings: user.settings.merge("communicator_slot_limit" => 5))

      expect(described_class.slots_for(user: user)[:limit]).to eq(5)
    end

    it "adds Pro add-on slots on top of the base limit" do
      user.update!(settings: user.settings.merge("extra_communicator_slots" => 3))

      expect(described_class.slots_for(user: user)).to include(limit: 5, available: 5)
    end

    it "treats a plan with no slots at all as reached" do
      user.update!(settings: user.settings.merge("paid_communicator_limit" => 0))

      expect(described_class.slots_for(user: user)).to include(
        limit: 0, used: 0, available: 0, limit_reached: true,
      )
    end

    it "uses caller-supplied status counts rather than re-querying" do
      counts = { ChildAccount::LOANER => 2, ChildAccount::SANDBOX => 9 }

      expect(described_class.slots_for(user: user, status_counts: counts)).to include(
        used: 2, on_loan: 2, active: 0, available: 0, limit_reached: true,
      )
    end
  end
end
