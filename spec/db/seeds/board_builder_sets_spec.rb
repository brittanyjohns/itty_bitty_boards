# Guards the authored Board Builder seed sets (db/seeds/board_builder_sets).
#
# Reads the .obf JSON directly — no DB, no seeding — so it's fast and fails the
# moment a template edit breaks the nav-row rule documented in that dir's
# README.md: every child reproduces the root's nav row cell-for-cell, so a
# category is always the same reach no matter which page you're on.
require "rails_helper"

module BoardBuilderSeedSets
  DIR = Rails.root.join("db", "seeds", "board_builder_sets")

  module_function

  def slugs
    Dir.children(DIR).select { |n| File.file?(DIR.join(n, "manifest.json")) }.sort
  end

  def load_obf(path) = JSON.parse(File.read(path))

  def manifest(slug) = load_obf(DIR.join(slug, "manifest.json"))

  def root_rel(slug) = manifest(slug).fetch("root")

  def child_rels(slug)
    manifest(slug).dig("paths", "boards").values.uniq.reject { |p| p == root_rel(slug) }.sort
  end

  def folder?(button) = button["load_board"].present?

  def board_path(button) = button.dig("load_board", "path")

  # [{label:, path:}] for one grid row, nil for an empty cell.
  def row_spec(obf, y)
    buttons = obf["buttons"].index_by { |b| b["id"] }
    obf.dig("grid", "order")[y].map do |id|
      next nil if id.nil?

      button = buttons.fetch(id)
      { label: button["label"], path: board_path(button) }
    end
  end
end

RSpec.describe "Board Builder seed sets" do
  include BoardBuilderSeedSets
  H = BoardBuilderSeedSets

  it "finds the authored sets" do
    expect(H.slugs).to include("core-60", "core-84")
  end

  H.slugs.each do |slug|
    describe slug do
      let(:dir) { H::DIR.join(slug) }
      let(:root_rel) { H.root_rel(slug) }
      let(:root) { H.load_obf(dir.join(root_rel)) }
      # The nav row is the root's bottom row.
      let(:nav_y) { root.dig("grid", "rows") - 1 }
      let(:root_nav) { H.row_spec(root, nav_y) }
      # Folder tiles the root places outside the nav row (Core 84's More),
      # as [[y, x, spec]].
      let(:root_off_nav) do
        buttons = root["buttons"].index_by { |b| b["id"] }
        root.dig("grid", "order").take(nav_y).flat_map.with_index do |row, y|
          row.filter_map.with_index do |id, x|
            button = id && buttons.fetch(id)
            next unless button && H.folder?(button)

            [y, x, { label: button["label"], path: H.board_path(button) }]
          end
        end
      end

      it "has children" do
        expect(H.child_rels(slug)).not_to be_empty
      end

      it "authors a nav row of folder tiles on the root" do
        expect(root_nav.compact.count { |t| t[:path] }).to be > 1
      end

      H.child_rels(slug).each do |rel|
        context File.basename(rel) do
          let(:child) { H.load_obf(dir.join(rel)) }
          let(:me) { "boards/#{File.basename(rel)}" }

          # What the child's nav row must be: the root's, except the tile
          # pointing at THIS page instead links back to the root.
          let(:expected_nav) do
            root_nav.map do |tile|
              next nil if tile.nil?
              next tile.merge(path: root_rel) if tile[:path] == me

              tile
            end
          end

          it "has the root's grid dimensions" do
            expect(child["grid"].slice("rows", "columns"))
              .to eq(root["grid"].slice("rows", "columns"))
          end

          it "reproduces the root's nav row cell-for-cell" do
            expect(H.row_spec(child, nav_y)).to eq(expected_nav)
          end

          it "puts the root's off-nav folder tiles at the same cells" do
            root_off_nav.each do |y, x, tile|
              expected = (tile[:path] == me) ? tile.merge(path: root_rel) : tile
              expect(H.row_spec(child, y)[x]).to eq(expected), "expected #{tile[:label]} at r#{y}c#{x}"
            end
          end

          it "links its own tile back to the root, never at itself" do
            selfies = child["buttons"].select { |b| H.board_path(b) == me }
            expect(selfies).to be_empty, "self-linking tile(s): #{selfies.map { |b| b['label'] }}"

            home = child["buttons"].select { |b| H.board_path(b) == root_rel }
            expect(home.map { |b| b["label"] }).to eq([child["name"]])
          end

          # Boards::TileDeduper collapses same-label same-kind tiles on seed,
          # keeping the lowest position — which would silently eat the nav-row
          # copy. See the README.
          it "never authors the same label twice with the same kind" do
            dupes = child["buttons"]
              .group_by { |b| [b["label"].to_s.strip.downcase, H.folder?(b)] }
              .select { |_key, group| group.size > 1 }
            expect(dupes).to be_empty, "TileDeduper would collapse: #{dupes.keys}"
          end

          # A page carrying twenty words in a sixty-cell grid opens mostly empty
          # next to a home board that fills every cell. Pages fill whole rows
          # from the top, and leave the last content row free — a PARTIAL final
          # row is worse than a short board, because rows are derived from the
          # tiles, so the gap sits at the right end of the last row rather than
          # shortening the page.
          describe "fullness" do
            let(:columns) { child.dig("grid", "columns") }
            # Cells above the nav row that the root pins for a folder tile
            # (Core 84's More), which content must lay itself out around.
            let(:pinned_cells) { root_off_nav.map { |y, x, _tile| [x, y] } }

            let(:content_cells) do
              child.dig("grid", "order").take(nav_y).flat_map.with_index do |row, y|
                row.filter_map.with_index { |id, x| [x, y, id] unless pinned_cells.include?([x, y]) }
              end
            end

            it "fills whole rows from the top, with no gaps" do
              placed = content_cells.map { |_x, _y, id| id }
              filled = placed.compact.size
              expect(placed.first(filled)).to all(be_present), "content is not contiguous from (0, 0)"
              expect(filled % columns).to eq(0),
                "#{filled} words in a #{columns}-wide grid leaves a partial final row"
            end

            # `More` is the drawer Boards::FolderPlacer tucks every build-added
            # page into (the authored home grid has no open cell), so it needs
            # more headroom than one row — see the README.
            it "leaves the last content row free (two, on the More drawer)" do
              spare_rows = child["name"].to_s.casecmp?("More") ? 2 : 1
              used_rows = content_cells.count { |_x, _y, id| id } / columns
              expect(used_rows).to be <= (nav_y - spare_rows),
                "#{child['name']} uses #{used_rows} of #{nav_y} content rows; " \
                "#{spare_rows} must stay free"
            end
          end

          it "gives every authored button a unique id and a cell" do
            ids = child["buttons"].map { |b| b["id"] }
            expect(ids.uniq).to eq(ids)

            placed = child.dig("grid", "order").flatten.compact
            expect(placed.uniq.sort).to eq(ids.sort)
          end
        end
      end
    end
  end

  # The standalone interest-routing templates are cloned into a set and stretched
  # to the root's columns, so a 12-word page lands sparser than any seeded one.
  describe "fringe-pages templates" do
    Dir.glob(H::DIR.join("fringe-pages", "*.obf")).sort.each do |path|
      context File.basename(path) do
        let(:obf) { H.load_obf(path) }

        it "fills its whole grid" do
          cells = obf.dig("grid", "order").flatten
          expect(cells.compact.size).to eq(cells.size)
          expect(cells.compact.size).to eq(obf["buttons"].size)
        end

        it "never authors the same label twice" do
          labels = obf["buttons"].map { |b| b["label"].to_s.strip.downcase }
          expect(labels.uniq).to eq(labels)
        end
      end
    end
  end
end
