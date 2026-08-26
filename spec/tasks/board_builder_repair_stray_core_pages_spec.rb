require "rails_helper"
require "rake"

RSpec.describe "board_builder:repair_stray_core_pages" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("board_builder:repair_stray_core_pages")
  end

  let(:task) { Rake::Task["board_builder:repair_stray_core_pages"] }
  let(:user) { create(:user) }

  let!(:root) do
    create(:board, user: user, name: "Classroom Poster", large_screen_columns: 4,
                   settings: { "builder_root" => true })
  end
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 4) }

  # The damage: a full copy of the core board sitting in the set as a page,
  # still carrying the seed's catalogue marker, plus the way-home tile
  # Boards::NavRowSync minted for it — labelled with its own name.
  let!(:stray) do
    create(:board, user: user, name: "Core 84", large_screen_columns: 4,
                   settings: { "builder_child" => true,
                               Boards::RobustSets::ROOT_MARKER => true,
                               Boards::RobustSets::SLUG_MARKER => "core-84" })
  end

  def tile(board, label, x:, y:, position:, target: nil, data: {})
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target, data: data)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  before do
    tile(root, "Food", x: 0, y: 0, position: 1, target: food.id)
    tile(food, "apple", x: 0, y: 0, position: 1)
    tile(stray, "I", x: 0, y: 0, position: 1)
    tile(stray, "Core 84", x: 1, y: 0, position: 2, target: root.id, data: { "nav_tile" => true })
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("DESTROY_STRAY")
  end

  # Reachable through the set, so the page itself is kept — only the minted
  # tile goes.
  context "when the stray page is still linked from the set" do
    before { tile(root, "Core 84", x: 1, y: 0, position: 2, target: stray.id) }

    it "reports without writing by default" do
      expect { task.invoke }.to output(/Dry run only.*stray core page/m).to_stdout
      expect(stray.board_images.reload.map(&:label)).to include("Core 84")
    end

    it "removes the minted way-home tile with DRY_RUN=false" do
      ENV["DRY_RUN"] = "false"

      expect { task.invoke }.to output(/Repaired/).to_stdout

      expect(stray.board_images.reload.map(&:label)).to eq(["I"])
      expect(Board.exists?(stray.id)).to be(true)
    end

    it "leaves the page alone even with DESTROY_STRAY=true" do
      ENV["DRY_RUN"] = "false"
      ENV["DESTROY_STRAY"] = "true"

      task.invoke

      expect(Board.exists?(stray.id)).to be(true)
    end
  end

  context "when the stray page is orphaned" do
    # Nothing links to it — the state board 6489 was found in — so destroying it
    # costs the set nothing. Still opt-in.
    before do
      root.board_group_boards.create!(
        board_group: create(:board_group, user: user, builder: true),
      )
      stray.board_group_boards.create!(board_group: root.board_groups.first)
      root.board_groups.first.update!(root_board_id: root.id)
    end

    it "keeps it unless DESTROY_STRAY is set" do
      ENV["DRY_RUN"] = "false"

      expect { task.invoke }.to output(/ORPHANED/).to_stdout

      expect(Board.exists?(stray.id)).to be(true)
    end

    it "destroys it with DESTROY_STRAY=true" do
      ENV["DRY_RUN"] = "false"
      ENV["DESTROY_STRAY"] = "true"

      task.invoke

      expect(Board.exists?(stray.id)).to be(false)
      expect(Board.exists?(food.id)).to be(true)
    end

    # A page whose content was sold as a PDF keeps its /pb/<slug> forever —
    # Board#block_marketplace_protected_destroy would abort the delete anyway,
    # but the task must say so rather than blow up mid-run.
    it "refuses to destroy a page a marketplace listing depends on" do
      ENV["DRY_RUN"] = "false"
      ENV["DESTROY_STRAY"] = "true"
      allow_any_instance_of(Board).to receive(:marketplace_protected?).and_return(true)

      expect { task.invoke }.to output(/NOT destroyed/).to_stdout

      expect(Board.exists?(stray.id)).to be(true)
    end
  end

  it "un-stacks two tiles sharing a cell anywhere in the set" do
    ENV["DRY_RUN"] = "false"
    stacked = tile(food, "banana", x: 0, y: 0, position: 2)

    task.invoke

    cells = food.board_images.reload.map { |bi| bi.layout["lg"].values_at("x", "y") }
    expect(cells.uniq.size).to eq(cells.size)
    expect(stacked.reload.layout["lg"].values_at("x", "y")).not_to eq([0, 0])
  end

  it "never touches a page that isn't a core-set copy" do
    ENV["DRY_RUN"] = "false"
    tile(food, "Food", x: 1, y: 0, position: 2, target: root.id, data: { "nav_tile" => true })

    task.invoke

    expect(food.board_images.reload.map(&:label)).to include("Food")
  end
end
