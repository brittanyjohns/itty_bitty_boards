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
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    VocabSets.seed_slug!("core-84")
    Dir.glob(Boards::FringeTemplates::SEED_DIR.join("*.obf")).sort.each do |p|
      Boards::FringeTemplates.seed_obf!(p)
    end
    # The Phrases layer rides every build now; seed the GLP function boards so
    # the integration test exercises the real (Phrases-inclusive) build path.
    Boards::GlpTemplates.seed!(admin: admin)
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

  # Pad the admin-owned seed root so the per-user clone starts with `remaining`
  # open cells — simulates a fuller authored grid (fewer reserved gaps) than the
  # repo's. Exposes whether the build's tile-adders honor the grid or spill.
  def shrink_seed_grid!(remaining: 0)
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID)
    seed_root = Boards::RobustSets.find_root("core-84")
    (seed_root.open_grid_cells - remaining).times do |i|
      seed_root.add_image(Image.create!(label: "pad#{i}", user_id: admin.id).id)
    end
    seed_root.reload
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

  # Regression for the "86 tiles instead of 84" report: when the authored grid
  # has no slack left (a fuller Core 84 than the repo seed), the catch-all
  # "My Favorites" tile and an early-stage quick-phrase strip used to spill onto
  # a stray extra row. The build must stay within the grid regardless of slack.
  it "never overflows the grid even when the seed has no open cells" do
    shrink_seed_grid!(remaining: 0)
    # Early-stage gestalt -> quick-phrase strip, the most aggressive cell user.
    communicator.update!(details: (communicator.details || {}).merge("glp_stage" => 1))

    root = build!([
      { "word" => "grandma", "category" => "Family & People" },
      { "word" => "toilet", "category" => "Bathroom" },
      { "word" => "dog", "category" => "Animals" },
    ])

    expect(root.status).to eq("complete")
    expect(root.board_images.count).to be <= CORE_84_GRID_CELLS
    expect(dead_folder_tiles(root)).to be_empty
  end

  # Aliased InterestCategories ("Family & People" -> People, "Health & Body" ->
  # Body) are seed-set interests; they must land in the cloned seed pages, not
  # spawn a spurious extra "My Favorites" folder tile on the home grid.
  it "routes aliased seed-set interests into the cloned People/Body pages" do
    root = build!([
      { "word" => "grandma", "category" => "Family & People" },
      { "word" => "tummy", "category" => "Health & Body" },
    ])

    people = Board.find(root.board_images.find { |bi| bi.label == "People" }.predictive_board_id)
    body   = Board.find(root.board_images.find { |bi| bi.label == "Body" }.predictive_board_id)
    expect(people.board_images.map { |bi| bi.label.to_s.downcase }).to include("grandma")
    expect(body.board_images.map { |bi| bi.label.to_s.downcase }).to include("tummy")

    favorites_tile = root.board_images.find { |bi| bi.label == "My Favorites" }
    if favorites_tile
      fav = Board.find(favorites_tile.predictive_board_id)
      expect(fav.board_images.map { |bi| bi.label.to_s.downcase }).not_to include("grandma", "tummy")
    end
  end

  # The early-stage quick-phrase strip must not surface a phrase the home board
  # already carries. "all done" is both an authored core word and a Transitions
  # gestalt, so an undeduped strip would add a second "all done" tile.
  it "does not duplicate an authored core word onto the home board via the phrase strip" do
    communicator.update!(details: (communicator.details || {}).merge("glp_stage" => 1))
    # Force the strip to pull the Transitions board (which contains "all done").
    allow(Boards::GlpTemplates).to receive(:recommended_for).and_return("glp-transitions-routines")

    root = build!([])

    all_done = root.board_images.select { |bi| bi.label.to_s.downcase == "all done" }
    expect(all_done.size).to eq(1)
    expect(root.board_images.count).to be <= CORE_84_GRID_CELLS
  end

  it "gives category folder tiles a curated image instead of a blank one" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID)
    # Curated, art-bearing admin images for an authored folder (People, cloned)
    # and a new fringe folder (Animals, added by the build). Lowercase labels to
    # prove case-insensitive matching against the capitalized folder labels.
    people_art = create(:image, label: "people", user_id: admin.id)
    create(:doc, documentable: people_art, user: admin)
    animals_art = create(:image, label: "animals", user_id: admin.id)
    create(:doc, documentable: animals_art, user: admin)

    root = build!([{ "word" => "dog", "category" => "Animals" }])

    people_tile = root.board_images.find { |bi| bi.label == "People" }
    animals_tile = root.board_images.find { |bi| bi.label == "Animals" }

    expect(Boards::ImageResolver.art?(people_tile.image)).to be(true)
    expect(Boards::ImageResolver.art?(animals_tile.image)).to be(true)
  end
end
