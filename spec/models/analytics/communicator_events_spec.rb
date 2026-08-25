# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::CommunicatorEvents do
  let(:user) { create(:user, plan_type: "free") }

  before { allow(PosthogService).to receive(:capture_for_user) }

  describe ".slot_limit_reached" do
    it "carries the limit and count that produced the refusal" do
      user.settings = (user.settings || {}).merge("communicator_slot_limit" => 1)
      user.save!
      create(:child_account, owner: user, user: user, status: ChildAccount::ACTIVE)

      described_class.slot_limit_reached(
        user: user,
        status: ChildAccount::ACTIVE,
        source: described_class::MYSPEAK_ONBOARDING,
      )

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_slot_limit_reached",
        properties: {
          status: ChildAccount::ACTIVE,
          limit: 1,
          count: 1,
          source: "myspeak_onboarding",
        },
      )
    end

    it "counts sandbox accounts against the sandbox limit for a sandbox refusal" do
      user.settings = (user.settings || {}).merge("sandbox_communicator_limit" => 2)
      user.save!

      described_class.slot_limit_reached(
        user: user,
        status: ChildAccount::SANDBOX,
        source: described_class::CHILD_ACCOUNTS,
      )

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_slot_limit_reached",
        properties: hash_including(limit: 2, count: 0, status: ChildAccount::SANDBOX),
      )
    end

    it "no-ops without a user" do
      described_class.slot_limit_reached(user: nil, status: ChildAccount::ACTIVE, source: "x")
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end

  describe ".account_created" do
    it "reports the status and the route that created it" do
      child = create(:child_account, owner: user, user: user, status: ChildAccount::SANDBOX)

      described_class.account_created(
        user: user, child: child, source: described_class::MYSPEAK_ONBOARDING,
      )

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_account_created",
        properties: {
          status: ChildAccount::SANDBOX,
          communicator_id: child.id,
          source: "myspeak_onboarding",
        },
      )
    end
  end

  describe ".myspeak_page_created" do
    it "reports the auto-minted page and the communicator it belongs to" do
      child = create(:child_account, owner: user, user: user)
      profile = child.create_profile!

      described_class.myspeak_page_created(
        user: user, profile: profile, child: child, source: described_class::CHILD_ACCOUNTS,
      )

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "myspeak_page_created",
        properties: {
          profile_id: profile.id,
          communicator_id: child.id,
          source: "child_accounts",
        },
      )
    end

    it "no-ops when no page was minted" do
      described_class.myspeak_page_created(user: user, profile: nil, child: nil, source: "x")
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end

  # Adoption is what a refusal turns into once the wizard can set up a page on
  # a communicator the user already has. It gets its own name because no
  # account was created — folding it into a create count would report growth
  # that never happened.
  describe ".myspeak_page_adopted" do
    it "reports the page and the communicator it was set up on" do
      child = create(:child_account, owner: user, user: user)
      profile = Profile.create!(profileable: child, username: child.username, slug: "quiet-fox")

      described_class.myspeak_page_adopted(
        user: user, profile: profile, child: child, source: described_class::MYSPEAK_ONBOARDING,
      )

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "myspeak_page_adopted",
        properties: {
          profile_id: profile.id,
          communicator_id: child.id,
          source: "myspeak_onboarding",
        },
      )
    end

    it "no-ops without a page" do
      described_class.myspeak_page_adopted(user: user, profile: nil, child: nil, source: "x")
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end

  describe ".public_page_create_blocked" do
    it "captures the 409 reason" do
      described_class.public_page_create_blocked(user: user, reason: "public_page_exists")

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "public_page_create_blocked",
        properties: { reason: "public_page_exists" },
      )
    end
  end
end
