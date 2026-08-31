require "rails_helper"

# Boards::PublishCascade decides whether publishing/unpublishing a Board
# Builder root needs to cascade to its set, and applies it. Members that
# already match the target don't count — re-saving a synced set never prompts.
RSpec.describe Boards::PublishCascade do
  let(:user) { create(:user) }

  # A builder root plus a builder BoardGroup owning `member_count` sub-boards.
  def build_builder_set(published: false, member_count: 2, members_published: false)
    root = create(:board, user: user, name: "Home", published: published,
                          settings: { "builder_root" => true })
    group = BoardGroup.create!(user: user, name: "Milo's Set", builder: true,
                               root_board_id: root.id)
    group.board_group_boards.create!(board: root)
    members = Array.new(member_count) do |i|
      m = create(:board, user: user, name: "Page #{i + 1}", published: members_published,
                         settings: { "builder_child" => true })
      group.board_group_boards.create!(board: m)
      m
    end
    [root, group, members]
  end

  describe "#needed?" do
    it "is true when publishing a root whose members are unpublished" do
      root, _group, _members = build_builder_set
      expect(described_class.new(root).needed?(published: true)).to be true
    end

    it "is false when every member already matches the target" do
      root, _group, _members = build_builder_set(members_published: true)
      expect(described_class.new(root).needed?(published: true)).to be false
    end

    it "is false for a board that is not a builder root" do
      plain = create(:board, user: user)
      expect(described_class.new(plain).needed?(published: true)).to be false
    end

    it "is false for a builder root with no member boards besides itself" do
      root = create(:board, user: user, settings: { "builder_root" => true })
      group = BoardGroup.create!(user: user, name: "Empty", builder: true, root_board_id: root.id)
      group.board_group_boards.create!(board: root)
      expect(described_class.new(root).needed?(published: true)).to be false
    end

    it "is true when unpublishing a root whose members are published" do
      root, _group, _members = build_builder_set(published: true, members_published: true)
      expect(described_class.new(root).needed?(published: false)).to be true
    end
  end

  describe "#summary" do
    it "reports the action, group, and exact affected count" do
      root, group, _members = build_builder_set(member_count: 3)
      summary = described_class.new(root).summary(published: true)

      expect(summary[:action]).to eq("publish")
      expect(summary[:board_group]).to eq({ id: group.id, name: "Milo's Set" })
      expect(summary[:affected][:count]).to eq(3)
      expect(summary[:affected][:names]).to contain_exactly("Page 1", "Page 2", "Page 3")
    end

    it "says unpublish when the target is false" do
      root, _group, _members = build_builder_set(published: true, members_published: true)
      expect(described_class.new(root).summary(published: false)[:action]).to eq("unpublish")
    end

    it "caps the name list but keeps the count exact" do
      root, _group, _members = build_builder_set(member_count: 14)
      summary = described_class.new(root).summary(published: true)

      expect(summary[:affected][:count]).to eq(14)
      expect(summary[:affected][:names].size).to eq(described_class::NAME_SAMPLE_LIMIT)
    end
  end

  describe "#apply!" do
    it "publishes every member and returns the count written" do
      root, _group, members = build_builder_set(member_count: 3)
      count = described_class.new(root).apply!(published: true)

      expect(count).to eq(3)
      expect(members.map { |m| m.reload.published }).to all(be true)
    end

    it "does not write the root board itself" do
      root, _group, _members = build_builder_set
      described_class.new(root).apply!(published: true)
      expect(root.reload.published).to be false
    end

    it "unpublishes every member" do
      root, _group, members = build_builder_set(published: true, members_published: true)
      described_class.new(root).apply!(published: false)
      expect(members.map { |m| m.reload.published }).to all(be false)
    end

    it "touches updated_at on the members it writes" do
      root, _group, members = build_builder_set
      before = members.first.updated_at
      travel_to(1.hour.from_now) { described_class.new(root).apply!(published: true) }
      expect(members.first.reload.updated_at).to be > before
    end

    it "is a no-op returning 0 for a non-builder board" do
      plain = create(:board, user: user)
      expect(described_class.new(plain).apply!(published: true)).to eq(0)
    end
  end

  describe "a member with published: nil" do
    # SQL `NOT (published = X)` evaluates to NULL (excluded) for a NULL row.
    # A legacy member whose `published` column is NULL must still be treated
    # as "not yet matching" any boolean target — otherwise it's silently
    # skipped by #needed?/#summary and never flipped by #apply!, in either
    # publish or unpublish direction.
    def build_set_with_null_member
      root = create(:board, user: user, name: "Home", published: false,
                            settings: { "builder_root" => true })
      group = BoardGroup.create!(user: user, name: "Milo's Set", builder: true,
                                 root_board_id: root.id)
      group.board_group_boards.create!(board: root)
      null_member = create(:board, user: user, name: "Null Page",
                                   settings: { "builder_child" => true })
      null_member.update_column(:published, nil)
      group.board_group_boards.create!(board: null_member)
      [root, null_member]
    end

    it "is included by #needed? and #summary when publishing" do
      root, null_member = build_set_with_null_member
      cascade = described_class.new(root)

      expect(cascade.needed?(published: true)).to be true
      summary = cascade.summary(published: true)
      expect(summary[:affected][:count]).to eq(1)
      expect(summary[:affected][:names]).to contain_exactly(null_member.name)
    end

    it "is flipped to true by #apply!(published: true)" do
      root, null_member = build_set_with_null_member
      described_class.new(root).apply!(published: true)
      expect(null_member.reload.published).to be true
    end

    it "is included by #needed? and flipped to false by #apply!(published: false)" do
      root, null_member = build_set_with_null_member
      cascade = described_class.new(root)

      expect(cascade.needed?(published: false)).to be true
      cascade.apply!(published: false)
      expect(null_member.reload.published).to be false
    end
  end

  # #633 — publishing is no longer admin-only, so the cascade must not be a
  # route to flipping a board you don't own. `add_to_groups` has no ownership
  # check, so a group can legitimately contain a foreign board.
  describe "a group member owned by another user" do
    let(:other_user) { create(:user) }

    def build_set_with_foreign_member
      root, group, members = build_builder_set
      foreign = create(:board, user: other_user, name: "Someone Else's", published: false)
      group.board_group_boards.create!(board: foreign)
      [root, members, foreign]
    end

    it "is excluded from #summary's affected count and names" do
      root, _members, _foreign = build_set_with_foreign_member

      summary = described_class.new(root).summary(published: true)

      expect(summary[:affected][:count]).to eq(2)
      expect(summary[:affected][:names]).not_to include("Someone Else's")
    end

    it "is not flipped by #apply!" do
      root, members, foreign = build_set_with_foreign_member

      expect(described_class.new(root).apply!(published: true)).to eq(2)
      expect(members.map { |m| m.reload.published }).to all(be true)
      expect(foreign.reload.published).to be false
    end

    it "alone does not make a cascade needed" do
      root = create(:board, user: user, settings: { "builder_root" => true })
      group = BoardGroup.create!(user: user, name: "Set", builder: true, root_board_id: root.id)
      group.board_group_boards.create!(board: root)
      group.board_group_boards.create!(
        board: create(:board, user: other_user, published: false),
      )

      expect(described_class.new(root).needed?(published: true)).to be false
    end
  end

  # Boards::SetCloner deep-clones a starter's sub-boards and stamps each
  # with settings["assignment_root_id"]. It creates NO BoardGroup, so those
  # pages were invisible to the cascade — publishing such a root left every
  # folder tile 404ing.
  describe "SetCloner sub-clones" do
    let(:other_user) { create(:user) }

    def build_clone_set(root_published: false, children_published: false)
      root = create(:board, user: user, name: "Starter", published: root_published)
      children = Array.new(2) do |i|
        create(:board, user: user, name: "Sub #{i + 1}", published: children_published,
                       settings: { "assignment_child" => true,
                                   "assignment_root_id" => root.id })
      end
      [root, children]
    end

    it "counts them in #needed? and #summary even with no BoardGroup" do
      root, children = build_clone_set
      cascade = described_class.new(root)

      expect(cascade.needed?(published: true)).to be true
      summary = cascade.summary(published: true)
      expect(summary[:board_group]).to be_nil
      expect(summary[:affected][:count]).to eq(2)
      expect(summary[:affected][:names]).to match_array(children.map(&:name))
    end

    it "publishes them with the root" do
      root, children = build_clone_set

      expect(described_class.new(root).apply!(published: true)).to eq(2)
      expect(children.map { |c| c.reload.published }).to all(be true)
    end

    it "unpublishes them with the root" do
      root, children = build_clone_set(root_published: true, children_published: true)

      described_class.new(root).apply!(published: false)
      expect(children.map { |c| c.reload.published }).to all(be false)
    end

    # #apply! writes with update_all, so Board's own marketplace guard never
    # fires for a member. The caller checks blocked_board_ids first — the new
    # membership source has to be visible to it too.
    it "reports a marketplace-protected clone in #blocked_board_ids on unpublish" do
      root, children = build_clone_set(root_published: true, children_published: true)
      protected_child = children.first
      expect(Boards::MarketplaceProtection).to receive(:protected_board_ids)
        .with(array_including(protected_child.id))
        .and_return(Set.new([protected_child.id]))

      blocked = described_class.new(root).blocked_board_ids(published: false)
      expect(blocked).to include(protected_child.id)
    end

    it "is not reachable for a clone owned by another user" do
      root, _children = build_clone_set
      foreign = create(:board, user: other_user, published: false,
                               settings: { "assignment_child" => true,
                                           "assignment_root_id" => root.id })

      described_class.new(root).apply!(published: true)
      expect(foreign.reload.published).to be false
    end
  end
end
