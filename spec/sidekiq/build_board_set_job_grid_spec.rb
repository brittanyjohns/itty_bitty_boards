require "rails_helper"

# Regression coverage for the Board Builder grid-overflow / dead-tile bug:
# an Extended build over the real Core 84 seed must (a) keep every authored
# folder tile working (no dead More/School/Time/Describe tiles) and (b) never
# push tiles past the authored 7x12 (84-cell) grid onto a stray extra row.
#
# Uses the real seeded set (slow ~10s) because the bug is specific to a full,
# nearly-grid-filling authored board — the tiny synthetic seed used elsewhere
# in build_board_set_job_spec can't reproduce it.
RSpec.describe BuildBoardSetJob, "Core 84 grid integrity", type: :model do
  CORE_84_GRID_CELLS = 84 # 7 rows x 12 cols, authored layout

  before do
    allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob)
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    VocabSets.seed_slug!("core-84")
    Dir.glob(Boards::FringeTemplates::SEED_DIR.join("*.obf")).sort.each do |p|
      Boards::FringeTemplates.seed_obf!(p)
    end
  end

  let(:user) { create(:user, id: 9001) }
  let(:communicator) { create(:child_account, user: user) }

  def precreate_root!(name: "Core 84")
    root = Board.new(name: name, user: user)
    root.board_type = "dynamic"
    root.assign_parent
    root.voice = VoiceService.normalize_voice(communicator.voice)
    root.generate_unique_slug
    root.settings = (root.settings || {}).merge("builder_root" => true)
    root.status = "building_board"
    root.save!
    cb = communicator.child_boards.create!(board: root, created_by_id: user.id)
    cb.update!(favorite: true)
    root
  end

  def build!(interests)
    root = precreate_root!
    norm = Boards::InterestWords.normalize_list(interests)
    cats = Boards::InterestWords.extract_categories(interests)
    described_class.new.perform(root.id, communicator.id, "extended", norm, cats)
    root.reload
  end

  # Every capitalized, multi-letter tile (a folder label like "Animals") must
  # carry a predictive link — a dead folder tile opens nothing when tapped.
  def dead_folder_tiles(board)
    board.board_images.select do |bi|
      label = bi.label.to_s
      label.length > 2 && label[0] == label[0].upcase && bi.predictive_board_id.nil?
    end
  end

  it "keeps every authored folder working and stays within the grid" do
    # More non-seed interest categories than the grid has open cells, to force
    # the overflow/cap path.
    root = build!([
      { "word" => "dog", "category" => "Animals" },
      { "word" => "guitar", "category" => "Music" },
      { "word" => "soccer", "category" => "Sports" },
      { "word" => "train", "category" => "Transportation" },
      { "word" => "shirt", "category" => "Clothing" },
    ])

    expect(root.status).to eq("complete")

    # No overflow: the build never spills onto a stray extra row.
    expect(root.board_images.count).to be <= CORE_84_GRID_CELLS

    # No dead tiles: the authored folders the planner used to strip are intact.
    expect(dead_folder_tiles(root)).to be_empty

    labels = root.board_images.map(&:label)
    expect(labels).to include("More", "School", "Time", "Describe")
    %w[More School Time Describe].each do |name|
      tile = root.board_images.find { |bi| bi.label == name }
      expect(tile.predictive_board_id).to be_present, "#{name} folder tile has no linked board"
    end

    # Nothing the child asked for is dropped: overflow interests land in a
    # working "My Favorites" rather than disappearing.
    favorites_tile = root.board_images.find { |bi| bi.label == "My Favorites" }
    expect(favorites_tile&.predictive_board_id).to be_present
    favorites = Board.find(favorites_tile.predictive_board_id)
    routed = root.board_images
      .select(&:predictive_board_id)
      .flat_map { |bi| Board.find(bi.predictive_board_id).board_images.map { |t| t.label.to_s.downcase } }
    %w[dog guitar soccer train shirt].each do |word|
      expect(routed).to include(word), "interest '#{word}' was dropped"
    end
  end

  it "builds a clean set with no interests (defaults only) within the grid" do
    root = build!([])

    expect(root.status).to eq("complete")
    expect(root.board_images.count).to be <= CORE_84_GRID_CELLS
    expect(dead_folder_tiles(root)).to be_empty
  end
end
