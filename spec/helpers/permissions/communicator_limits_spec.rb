# frozen_string_literal: true

require "rails_helper"

RSpec.describe Permissions::CommunicatorLimits do
  describe ".can_create?" do
    context "demo communicators (the MySpeak ID) on the free plan" do
      # created_at outside the soft-trial window so the user stays on `free`
      # (a fresh free user is flipped to basic_trial by set_soft_trial_plan).
      let(:user) { create(:user, created_at: 2.months.ago) }

      before do
        user.settings ||= {}
        user.settings["demo_communicator_limit"] = 1
        user.settings["paid_communicator_limit"] = 0
        user.save!
      end

      it "allows the first MySpeak demo communicator" do
        allowed, status, error = described_class.can_create?(user: user, is_demo: true)

        expect(allowed).to be(true)
        expect(status).to eq(:ok)
        expect(error).to be_nil
      end

      it "blocks a second demo communicator once the slot is used" do
        create(:child_account, user: user, owner: user, is_demo: true)

        allowed, status, error = described_class.can_create?(user: user, is_demo: true)

        expect(allowed).to be(false)
        expect(status).to eq(:unprocessable_entity)
        expect(error).to match(/limit reached/i)
      end

      it "still blocks paid communicators (free plan includes none)" do
        allowed, status, error = described_class.can_create?(user: user, is_demo: false)

        expect(allowed).to be(false)
        expect(status).to eq(:forbidden)
        expect(error).to match(/does not include/i)
      end
    end
  end
end
