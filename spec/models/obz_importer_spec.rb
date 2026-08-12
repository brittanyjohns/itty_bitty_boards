require "rails_helper"
require "zip"

RSpec.describe ObzImporter, type: :model do
  let(:user) { create(:user) }
  let(:board_group) { create(:board_group, user: user) }

  def fixture_bytes(name)
    File.binread(Rails.root.join("spec/data", name))
  end

  describe "#import! with a single-board package" do
    subject(:result) do
      described_class.new(
        fixture_bytes("simple.obz"), user,
        board_group: board_group, import_all: true,
      ).import!
    end

    it "creates one board for the lone .obf and returns it as the root" do
      expect { result }.to change { user.boards.count }.by(1)
      expect(result[:root_board]).to be_a(Board)
      expect(result[:root_board].name).to eq("Simple Board")
      expect(result[:root_board].obf_id).to eq("simple")
    end

    it "sets the BoardGroup root and original_obf_root_id" do
      result
      board_group.reload
      expect(board_group.root_board_id).to eq(result[:root_board].id)
      expect(board_group.original_obf_root_id).to eq("simple")
    end

    it "imports buttons as board_images using the obf grid" do
      result
      board = result[:root_board]
      expect(board.board_images.count).to eq(2)
      expect(board.board_images.map(&:label)).to contain_exactly("happy", "sad")
    end
  end

  describe "#import! with linked boards" do
    subject(:result) do
      described_class.new(
        fixture_bytes("links.obz"), user,
        board_group: board_group, import_all: true,
      ).import!
    end

    it "imports every board in the package" do
      expect { result }.to change { user.boards.count }.by(3)
      expect(result[:boards].keys).to contain_exactly("simple", "simple2", "simple3")
    end

    it "wires load_board path references into predictive_board_id (regression: links were silently dropped)" do
      result
      root = result[:root_board]
      linked_targets = root.board_images
                           .where.not(predictive_board_id: nil)
                           .map(&:predictive_board_id)

      expect(linked_targets).not_to be_empty,
        "expected at least one button on the root board to link to another imported board, " \
        "but every BoardImage on root has a nil predictive_board_id"

      sibling_ids = (result[:boards].values - [root]).map(&:id)
      expect(linked_targets).to all(be_in(sibling_ids))
    end
  end

  # An OBF back button is an ordinary button with load_board — the format has no
  # marker for it — so a folder-link walk would climb out of the page it started
  # on and treat the whole set as that page's subboards.
  describe "#import! with a back button" do
    def obz_with_back_button
      root = {
        format: "open-board-0.1", id: "home", locale: "en", name: "Home",
        grid: { rows: 1, columns: 1, order: [[1]] },
        buttons: [{ id: 1, label: "feelings", load_board: { path: "boards/feelings.obf" } }],
        images: [], sounds: []
      }
      child = {
        format: "open-board-0.1", id: "feelings", locale: "en", name: "Feelings",
        grid: { rows: 1, columns: 2, order: [[1, 2]] },
        buttons: [
          { id: 1, label: "happy" },
          { id: 2, label: "back", load_board: { path: "boards/home.obf" } },
        ],
        images: [], sounds: []
      }
      manifest = {
        format: "open-board-0.1", root: "boards/home.obf",
        paths: { boards: { "home" => "boards/home.obf", "feelings" => "boards/feelings.obf" } }
      }

      buffer = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("manifest.json")
        zip.write(manifest.to_json)
        zip.put_next_entry("boards/home.obf")
        zip.write(root.to_json)
        zip.put_next_entry("boards/feelings.obf")
        zip.write(child.to_json)
      end
      buffer.string
    end

    subject(:result) do
      described_class.new(obz_with_back_button, user,
                          board_group: board_group, import_all: true).import!
    end

    it "flags the child's back button and leaves the parent's folder tile alone" do
      result
      home = result[:boards]["home"]
      feelings = result[:boards]["feelings"]

      back = feelings.board_images.find_by(predictive_board_id: home.id)
      descent = home.board_images.find_by(predictive_board_id: feelings.id)

      expect(back.back_tile?).to be(true)
      expect(descent.back_tile?).to be(false)
    end

    it "does not report the set root as a subboard of the child page" do
      result
      feelings = result[:boards]["feelings"]

      expect(Boards::SubboardTree.new(feelings).any?).to be(false)
    end
  end

  describe "#import! — image policy audit on BoardGroup.settings" do
    it "stamps imported_from_obf with include_images=false by default" do
      described_class.new(fixture_bytes("simple.obz"), user, board_group: board_group).import!
      audit = board_group.reload.settings["imported_from_obf"]
      expect(audit).to include(
        "include_images" => false,
        "license_acknowledged" => false,
        "imported_by_user_id" => user.id,
      )
      expect(audit["acknowledged_at"]).to be_nil
    end

    it "records the acknowledgment timestamp + acknowledger when opted in" do
      described_class.new(
        fixture_bytes("simple.obz"), user, board_group: board_group,
        import_options: {
          include_images: true,
          license_acknowledged: true,
          acknowledged_by_user_id: user.id,
        }
      ).import!
      audit = board_group.reload.settings["imported_from_obf"]
      expect(audit).to include(
        "include_images" => true,
        "license_acknowledged" => true,
        "acknowledged_by_user_id" => user.id,
      )
      expect(audit["acknowledged_at"]).to be_present
    end

    it "marks freshly-created Images is_private: true regardless of opt-in" do
      described_class.new(fixture_bytes("simple.obz"), user, board_group: board_group).import!
      imported = user.images.where(label: ["happy", "sad"])
      expect(imported.count).to eq(2)
      expect(imported.pluck(:is_private)).to all(eq(true))
    end
  end

  describe "#import! with a malformed archive" do
    it "raises ObzImporter::ImportError when the zip has no .obf entries" do
      empty_zip = StringIO.new
      Zip::File.open_buffer(empty_zip) do |zip|
        zip.get_output_stream("readme.txt") { |io| io.write("nothing here") }
      end
      empty_zip.rewind

      expect {
        described_class.new(empty_zip.read, user, board_group: board_group).import!
      }.to raise_error(ObzImporter::ImportError, /No \.obf files/i)
    end
  end
end
