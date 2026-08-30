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
      expect(user.settings["paid_communicator_limit"]).to eq(1)
      # board_limit is NOT stamped — it resolves from plan_type at read time,
      # and settings only ever holds a deliberate admin override (#796).
      expect(user.settings).not_to have_key("board_limit")
      expect(user.board_limit).to eq(User::FREE_PLAN_LIMITS["board_limit"])
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

  # Issue #796: there is ONE cap and it is boards. A Board Builder set's member
  # boards (root + children) count exactly like any others — group membership
  # affects no limit at all, and Board Sets themselves are uncapped.
  # countable_board_group_count survives as a usage number, not a gate.
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

    it "1 builder set (root + 3 children) => 4 boards / 1 set" do
      make_builder_set(user, children: 3)
      expect(user.countable_board_count).to eq(4)
      expect(user.countable_board_group_count).to eq(1)
    end

    it "1 builder set + 2 standalone boards => 6 boards / 1 set" do
      make_builder_set(user, children: 3)
      2.times { |i| create(:board, user: user, name: "Standalone #{i}") }
      expect(user.countable_board_count).to eq(6)
      expect(user.countable_board_group_count).to eq(1)
    end

    it "1 builder set + 1 hand-made group (2 boards) => 6 boards / 2 sets" do
      make_builder_set(user, children: 3)
      make_manual_group(user, boards: 2)
      expect(user.countable_board_count).to eq(6)
      expect(user.countable_board_group_count).to eq(2)
    end

    it "2 builder sets => 7 boards / 2 sets" do
      make_builder_set(user, children: 3, name: "Set A")
      make_builder_set(user, children: 2, name: "Set B")
      expect(user.countable_board_count).to eq(7)
      expect(user.countable_board_group_count).to eq(2)
    end

    it "puts builder-set boards in the editable pool, since they consume slots" do
      group = make_builder_set(user, children: 3)
      member_ids = group.board_group_boards.map(&:board_id)
      user.settings["board_limit"] = 10
      user.save!

      expect(User.find(user.id).top_editable_board_ids).to include(*member_ids)
    end

    it "no longer has a separate Board Set cap" do
      expect(user).not_to respond_to(:at_board_group_limit?)
      expect(user).not_to respond_to(:board_group_limit)
      expect(user).not_to respond_to(:builder_grouped_board_ids)
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
