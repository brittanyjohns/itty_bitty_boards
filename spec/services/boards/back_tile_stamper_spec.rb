require "rails_helper"

RSpec.describe Boards::BackTileStamper do
  let(:user) { create(:user) }

  def board(name)
    create(:board, user: user, name: name)
  end

  def link(from, to, data: {})
    create(:board_image, board: from, predictive_board_id: to.id, data: data)
  end

  def group_for(root, *members)
    group = create(:board_group, user: user)
    ([root] + members).each { |b| group.board_group_boards.create!(board: b) }
    group.update!(root_board_id: root.id)
    group
  end

  def stamped?(board_image)
    board_image.reload.data["back_tile"] == true
  end

  it "leaves a descent into a subboard alone" do
    root = board("Home")
    page = board("Food")
    tile = link(root, page)

    described_class.new(group_for(root, page)).call

    expect(stamped?(tile)).to be(false)
  end

  it "marks a go-back tile pointing at the root" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    back = link(page, root)

    described_class.new(group_for(root, page)).call

    expect(stamped?(back)).to be(true)
  end

  it "marks a nav-row link between siblings" do
    root = board("Home")
    food = board("Food")
    play = board("Play")
    link(root, food)
    link(root, play)
    lateral = link(food, play)

    described_class.new(group_for(root, food, play)).call

    expect(stamped?(lateral)).to be(true)
  end

  it "marks a go-back tile pointing at a mid-level parent" do
    root = board("Home")
    food = board("Food")
    snacks = board("Snacks")
    link(root, food)
    link(food, snacks)
    back = link(snacks, food)

    described_class.new(group_for(root, food, snacks)).call

    expect(stamped?(back)).to be(true)
  end

  # The reported bug: "Spell a word" is not linked to home, so it has no depth.
  # Its go-back tile to the root must still read as a way back, not as the page
  # owning the root.
  it "marks a link to the root from a board nothing links to" do
    root = board("With a Medic")
    orphan = board("Spell a word")
    back = link(orphan, root)

    described_class.new(group_for(root, orphan)).call

    expect(stamped?(back)).to be(true)
  end

  it "leaves a descent from an unreachable board alone when the target is deeper" do
    root = board("With a Medic")
    orphan = board("Spell a word")
    child = board("QWERTY Keyboard")
    descent = link(orphan, child) # nothing links to `orphan`, so it has no depth

    described_class.new(group_for(root, orphan, child)).call

    # `child` is unreachable too, so it has no depth and the link is left alone
    # rather than guessed at.
    expect(stamped?(descent)).to be(false)
  end

  it "ignores a tile pointing out of the set" do
    root = board("Home")
    outsider = board("Someone else's board")
    tile = link(root, outsider)

    described_class.new(group_for(root)).call

    expect(stamped?(tile)).to be(false)
  end

  it "ignores a tile pointing back at its own board" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    self_tile = create(:board_image, board: page, predictive_board_id: page.id)

    described_class.new(group_for(root, page)).call

    expect(stamped?(self_tile)).to be(false)
  end

  it "writes nothing on a dry run" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    back = link(page, root)

    result = described_class.new(group_for(root, page), dry_run: true).call

    expect(result).to contain_exactly(back)
    expect(stamped?(back)).to be(false)
  end

  it "is idempotent" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    back = link(page, root)
    group = group_for(root, page)

    described_class.new(group).call

    expect(described_class.new(group).call).to be_empty
    expect(stamped?(back)).to be(true)
  end

  it "preserves other data keys on the tile" do
    root = board("Home")
    page = board("Food")
    link(root, page)
    back = link(page, root, data: { "mute_name" => true })

    described_class.new(group_for(root, page)).call

    expect(back.reload.data).to include("mute_name" => true, "back_tile" => true)
  end

  it "no-ops when the group has no root board" do
    root = board("Home")
    page = board("Food")
    back = link(page, root)
    group = group_for(root, page)
    group.update!(root_board_id: nil)

    expect(described_class.new(group).call).to eq([])
    expect(stamped?(back)).to be(false)
  end
end
