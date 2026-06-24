require "rails_helper"

RSpec.describe Boards::SetGraphBuilder do
  let(:user) { FactoryBot.create(:user) }

  # Build a tile on `board`. A folder tile links to `links_to` (a Board);
  # a word tile passes links_to: nil. The label drives duplicate-word stats.
  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(
      :board_image,
      board: board,
      image: image,
      predictive_board_id: links_to&.id,
    )
  end

  # A builder set:
  #   Home (root, depth 0)
  #     ├─ Food (depth 1) ── Fruit (depth 2)
  #     └─ Play (depth 1)
  #   Orphan (in set, nothing links to it → unreachable)
  #
  # Duplicate words: "more" (Home + Food), "apple" (Food + Fruit).
  def build_set!
    home   = FactoryBot.create(:board, user: user, name: "Home")
    food   = FactoryBot.create(:board, user: user, name: "Food")
    play   = FactoryBot.create(:board, user: user, name: "Play")
    fruit  = FactoryBot.create(:board, user: user, name: "Fruit")
    orphan = FactoryBot.create(:board, user: user, name: "Orphan")

    add_tile(home, label: "Food", links_to: food)
    add_tile(home, label: "Play", links_to: play)
    add_tile(home, label: "I")
    add_tile(home, label: "more")

    add_tile(food, label: "Fruit", links_to: fruit)
    add_tile(food, label: "apple")
    add_tile(food, label: "more")

    add_tile(play, label: "go")

    add_tile(fruit, label: "apple")

    add_tile(orphan, label: "lonely")

    group = FactoryBot.create(:board_group, user: user, builder: true, layout: {})
    [home, food, play, fruit, orphan].each { |b| group.add_board(b) }
    group.update!(root_board_id: home.id)
    { group: group, home: home, food: food, play: play, fruit: fruit, orphan: orphan }
  end

  subject(:graph) { described_class.new(set[:group]).call }

  let(:set) { build_set! }

  it "returns top-level set metadata" do
    expect(graph[:id]).to eq(set[:group].id)
    expect(graph[:name]).to eq(set[:group].name)
    expect(graph[:builder]).to be(true)
    expect(graph[:root_board_id]).to eq(set[:home].id)
  end

  it "computes depth and reachability per board via BFS from the root" do
    by_id = graph[:boards].index_by { |b| b[:id] }

    expect(by_id[set[:home].id][:depth]).to eq(0)
    expect(by_id[set[:food].id][:depth]).to eq(1)
    expect(by_id[set[:play].id][:depth]).to eq(1)
    expect(by_id[set[:fruit].id][:depth]).to eq(2)

    expect(by_id[set[:home].id][:reachable]).to be(true)
    expect(by_id[set[:fruit].id][:reachable]).to be(true)
  end

  it "marks a board nothing links to as unreachable with null depth" do
    orphan = graph[:boards].find { |b| b[:id] == set[:orphan].id }
    expect(orphan[:reachable]).to be(false)
    expect(orphan[:depth]).to be_nil
  end

  it "distinguishes folder tiles from word tiles" do
    home = graph[:boards].find { |b| b[:id] == set[:home].id }

    folder = home[:tiles].find { |t| t[:label] == "Food" }
    expect(folder[:is_folder]).to be(true)
    expect(folder[:links_to_board_id]).to eq(set[:food].id)

    word = home[:tiles].find { |t| t[:label] == "I" }
    expect(word[:is_folder]).to be(false)
    expect(word[:links_to_board_id]).to be_nil
  end

  it "exposes each tile's BoardImage id and image_url" do
    home = graph[:boards].find { |b| b[:id] == set[:home].id }
    bi = set[:home].board_images.find_by(label: "I")
    tile = home[:tiles].find { |t| t[:label] == "I" }
    expect(tile[:id]).to eq(bi.id)
    expect(tile).to have_key(:image_url)
  end

  it "builds edges only for links whose target board is in the set" do
    expect(graph[:edges]).to contain_exactly(
      a_hash_including(from: set[:home].id, to: set[:food].id, via_label: "Food"),
      a_hash_including(from: set[:home].id, to: set[:play].id, via_label: "Play"),
      a_hash_including(from: set[:food].id, to: set[:fruit].id, via_label: "Fruit"),
    )
  end

  it "computes set-wide stats" do
    stats = graph[:stats]
    expect(stats[:boards]).to eq(5)
    expect(stats[:words]).to eq(7) # I, more, apple, more, go, apple, lonely
    expect(stats[:max_depth]).to eq(2)
    expect(stats[:duplicate_words]).to eq(2) # "more" and "apple"
    expect(stats[:unreachable_boards]).to eq(1)
  end

  it "counts a duplicate label once even when it appears on more than two boards" do
    # add "more" to a third board (play) — still a single duplicate label
    add_tile(set[:play], label: "more")
    expect(described_class.new(set[:group]).call[:stats][:duplicate_words]).to eq(2)
  end

  describe "N+1 safety" do
    def count_queries
      count = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name].to_s =~ /SCHEMA|TRANSACTION/
        next if payload[:sql] =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

        count += 1
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end

    it "does not scale query count with the number of boards/tiles" do
      small = build_set!
      large = build_set!
      # double the size of the large set
      4.times do |i|
        extra = FactoryBot.create(:board, user: user, name: "Extra #{i}")
        add_tile(extra, label: "x#{i}")
        large[:group].add_board(extra)
      end

      small_count = count_queries { described_class.new(small[:group]).call }
      large_count = count_queries { described_class.new(large[:group]).call }

      expect(large_count).to eq(small_count)
    end
  end

  describe "root-BFS fallback for an unbackfilled set" do
    it "resolves boards from root_board_id when membership is empty" do
      home = FactoryBot.create(:board, user: user, name: "Home")
      child = FactoryBot.create(:board, user: user, name: "Child")
      add_tile(home, label: "Child", links_to: child)
      add_tile(child, label: "word")

      group = FactoryBot.create(:board_group, user: user, builder: true, layout: {})
      group.update!(root_board_id: home.id) # no board_group_boards added

      result = described_class.new(group).call
      ids = result[:boards].map { |b| b[:id] }
      expect(ids).to contain_exactly(home.id, child.id)
      expect(result[:stats][:boards]).to eq(2)
    end
  end
end
