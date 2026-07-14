# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, "plan limits", type: :model do
  describe "sandbox (legacy demo) communicator limits" do
    # Every Free user gets one sandbox communicator (the MySpeak ID).
    # Pro gets ten; Basic has none.
    it "grants one sandbox communicator to Free, ten to Pro, none to Basic" do
      expect(User::FREE_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
      expect(User::BASIC_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::PRO_PLAN_LIMITS["demo_communicator_limit"]).to eq(10)
    end

    it "no longer defines a MySpeak plan tier" do
      expect(defined?(User::MYSPEAK_PLAN_LIMITS)).to be_nil
    end
  end

  # Slot pool sizes (self-created or claimed):
  #   Free  — 1.
  #   Basic — 2.
  #   Pro   — 5.  (Bumped from 3 on 2026-05-31; see pricing-structure.md.)
  describe "paid (loaner+active) communicator slot limits" do
    it "matches the locked slot math from the spec" do
      expect(User::FREE_PLAN_LIMITS["paid_communicator_limit"]).to eq(1)
      expect(User::BASIC_PLAN_LIMITS["paid_communicator_limit"]).to eq(2)
      expect(User::PRO_PLAN_LIMITS["paid_communicator_limit"]).to eq(5)
    end
  end

  describe "#setup_free_limits" do
    it "seeds the free-tier slot math (1 sandbox + 1 claimable)" do
      user = build(:user)
      user.setup_free_limits

      expect(user.settings["demo_communicator_limit"]).to eq(1)
      expect(user.settings["board_limit"]).to eq(1)
      expect(user.settings["paid_communicator_limit"]).to eq(1)
      # ai_monthly_limit is no longer written — AI is credit-gated.
      expect(user.settings).not_to have_key("ai_monthly_limit")
    end
  end

  describe "#countable_board_count / #at_board_limit? (board-limit counting)" do
    let(:user) { create(:free_user) } # board_limit 1

    it "counts the user's own non-predefined boards" do
      create(:board, user: user)
      expect(user.countable_board_count).to eq(1)
      expect(user.at_board_limit?).to be(true)
    end

    it "excludes predefined boards from the count" do
      create(:board, user: user, predefined: true)
      expect(user.countable_board_count).to eq(0)
      expect(user.at_board_limit?).to be(false)
    end

    it "never limits admins" do
      admin = create(:admin_user)
      create(:board, user: admin)
      expect(admin.at_board_limit?).to be(false)
    end

    it "exposes can_create_boards as the inverse of at_board_limit?" do
      expect(user.can_create_boards).to be(true)
      create(:board, user: user)
      # Fresh instance — countable_board_count memoizes, matching the controller.
      expect(User.find(user.id).can_create_boards).to be(false)
    end
  end

  # Issue #407: a Board Builder set is a real `builder: true` BoardGroup. It
  # costs EXACTLY one board-set slot and ZERO board slots — its member boards
  # (root + children) are excluded from countable_board_count, and the group
  # itself counts as one in countable_board_group_count. Hand-made groups are
  # unchanged in this phase: their member boards still count against board_limit.
  describe "builder-set vs standalone vs hand-made counting matrix" do
    let(:user) { create(:free_user) }

    # A builder set: root + N children, all members of a `builder: true` group.
    def make_builder_set(owner, children: 3, name: "Built Set")
      root  = create(:board, user: owner, name: "#{name} Root")
      group = owner.board_groups.create!(name: name, builder: true)
      group.board_group_boards.create!(board: root)
      group.update!(root_board_id: root.id)
      children.times do |i|
        child = create(:board, user: owner, name: "#{name} Child #{i}")
        group.board_group_boards.create!(board: child)
      end
      group
    end

    # A hand-made set: a non-builder group whose member boards still count.
    def make_manual_group(owner, boards: 2, name: "Manual Set")
      group = owner.board_groups.create!(name: name) # builder defaults to false
      boards.times { |i| group.board_group_boards.create!(board: create(:board, user: owner, name: "#{name} #{i}")) }
      group
    end

    it "new user, nothing => 0 boards / 0 sets" do
      expect(user.countable_board_count).to eq(0)
      expect(user.countable_board_group_count).to eq(0)
    end

    it "1 standalone board => 1 board / 0 sets" do
      create(:board, user: user)
      expect(user.countable_board_count).to eq(1)
      expect(user.countable_board_group_count).to eq(0)
    end

    it "1 builder set (root + 3 children) => 0 boards / 1 set" do
      make_builder_set(user, children: 3)
      expect(user.countable_board_count).to eq(0)
      expect(user.countable_board_group_count).to eq(1)
    end

    it "1 builder set + 2 standalone boards => 2 boards / 1 set" do
      make_builder_set(user, children: 3)
      2.times { |i| create(:board, user: user, name: "Standalone #{i}") }
      expect(user.countable_board_count).to eq(2)
      expect(user.countable_board_group_count).to eq(1)
    end

    it "1 builder set + 1 hand-made group (2 boards) => 2 boards / 2 sets" do
      make_builder_set(user, children: 3)
      make_manual_group(user, boards: 2)
      # Hand-made members still count against board_limit in this phase.
      expect(user.countable_board_count).to eq(2)
      expect(user.countable_board_group_count).to eq(2)
    end

    it "2 builder sets => 0 boards / 2 sets" do
      make_builder_set(user, children: 3, name: "Set A")
      make_builder_set(user, children: 2, name: "Set B")
      expect(user.countable_board_count).to eq(0)
      expect(user.countable_board_group_count).to eq(2)
    end
  end

  describe "#has_myspeak_feature?" do
    it "is true when the user has a sandbox communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 1 })
      expect(user.has_myspeak_feature?).to be(true)
    end

    it "is false when the user has no sandbox communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 0 })
      expect(user.has_myspeak_feature?).to be(false)
    end
  end
end
