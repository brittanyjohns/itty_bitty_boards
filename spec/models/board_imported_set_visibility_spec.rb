require "rails_helper"

# An imported (.obz) set is one board as far as every listing is concerned: its
# ROOT. The interior pages are sub-boards. This used to be enforced with a
# blanket `where(obf_id: nil)`, which hid the root too — an import was
# unreachable from anywhere but its own group.
RSpec.describe "imported board set visibility", type: :model do
  let(:user) { create(:user) }
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  describe "Board.searchable" do
    it "includes an imported set's root board" do
      root = create(:board, user: user, name: "Imported Core", obf_id: "core", board_type: "dynamic", sub_board: false)

      expect(Board.searchable).to include(root)
    end

    it "excludes an imported set's interior pages" do
      # update_column: Board#check_is_sub_board re-derives the flag on save from
      # who links in, so the attribute can't just be assigned on create.
      page = create(:board, user: user, name: "Imported Food", obf_id: "food", board_type: "category")
      page.update_column(:sub_board, true)

      expect(Board.searchable).not_to include(page)
    end

    it "still includes a hand-made sub-board" do
      sub = create(:board, user: user, name: "My Sub Board", board_type: "category")
      sub.update_column(:sub_board, true)

      expect(Board.searchable).to include(sub)
    end
  end

  describe "Board.admin_owned_boards" do
    it "includes an admin-owned imported root" do
      root = create(:board, user: admin, name: "Imported Catalogue Board",
                            obf_id: "cat", sub_board: false, published: true, predefined: true)

      expect(Board.admin_owned_boards).to include(root)
      expect(Board.public_boards).to include(root)
    end

    it "excludes that set's interior pages" do
      page = create(:board, user: admin, name: "Imported Catalogue Page",
                            obf_id: "cat-food", board_type: "category", published: true, predefined: true)
      page.update_column(:sub_board, true)

      expect(Board.admin_owned_boards).not_to include(page)
    end

    # Board Builder seed material is admin-owned + predefined + published so the
    # builder can clone it, not because it belongs in the public catalogue. It
    # was kept out as a side effect of the old OBF filter.
    it "excludes a seeded robust-set root" do
      root = create(:board, user: admin, name: "Core 84", obf_id: "core-84",
                            sub_board: false, published: true, predefined: true,
                            settings: { Boards::RobustSets::ROOT_MARKER => true })

      expect(Board.admin_owned_boards).not_to include(root)
    end

    it "excludes a fringe page template" do
      template = create(:board, user: admin, name: "Animals", obf_id: "fringe:animals",
                                sub_board: false, published: true, predefined: true,
                                settings: { Boards::FringeTemplates::TEMPLATE_MARKER => "animals" })

      expect(Board.admin_owned_boards).not_to include(template)
    end
  end

  describe "Board.main_boards" do
    it "collapses a classified set to its root" do
      root = create(:board, user: user, name: "Imported Core", obf_id: "core", board_type: "dynamic")
      page = create(:board, user: user, name: "Imported Food", obf_id: "food", board_type: "category")
      create(:board_image, board: root, predictive_board_id: page.id)

      Boards::ImportedSetClassifier.new(root).call

      expect(Board.main_boards).to include(root)
      expect(Board.main_boards).not_to include(page)
    end
  end
end
