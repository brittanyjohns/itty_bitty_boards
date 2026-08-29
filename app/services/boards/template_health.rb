module Boards
  # A read-only health report for ONE Board Builder template board, shared by the
  # admin index and show screens so the two can never disagree.
  #
  # STRICTLY READ-ONLY, and that is not incidental. `Board#open_grid_cells` — the
  # obvious way to ask "how full is this grid" — opens with `update_board_layout`,
  # which does `self.save` and rewrites every tile's `layout`. Calling it from an
  # index that renders ~60 template boards would mass-write on a GET. The distinct
  # occupied-cell count is computed here instead, from the same `layout["lg"]`
  # cells, without touching the database.
  #
  # Why the screen exists: a template is cloned verbatim into every set built from
  # it, so one stacked cell on a seed is a stacked cell in every user's board —
  # and nothing in the app surfaced that before you went looking.
  class TemplateHealth
    # lg is the screen a seed's grid is AUTHORED in; md/sm are derived from it.
    # A finding on lg is the finding that matters, and summing all three would
    # triple-count one stacked tile.
    AUTHORED_SCREEN = "lg".freeze

    attr_reader :board, :kind, :category, :slug

    # kind: :fringe | :robust_root | :robust_page
    def initialize(board, kind:, category: nil, slug: nil, duplicate_registration: false)
      @board = board
      @kind = kind
      @category = category
      @slug = slug
      @duplicate_registration = duplicate_registration
    end

    def tile_count = tiles.size

    def columns
      @columns ||= [board.get_number_of_columns(AUTHORED_SCREEN).to_i, 1].max
    end

    # max(y + h) over the authored cells — the same arithmetic
    # rows_for_screen_size does, without its side effects.
    def rows
      @rows ||= cells.filter_map { |cell| cell["y"].to_i + [cell["h"].to_i, 1].max }.max.to_i
    end

    def grid_label = "#{rows}x#{columns}"

    # Tiles sharing a cell with an earlier tile, or parked past the column count.
    # dry_run returns the count before any save (layout_repacker.rb:117).
    def displaced_tiles
      @displaced_tiles ||= Boards::LayoutRepacker.unstack_screen!(board, AUTHORED_SCREEN, dry_run: true)
    end

    def duplicate_tiles
      @duplicate_tiles ||= Boards::TileDeduper.duplicate_groups(board).sum { |_key, group| group.size - 1 }
    end

    # DISTINCT cells claimed. Compared against tile_count, this is what exposes a
    # stacked cell: a completely full grid reports a phantom free cell because
    # two tiles share one.
    def occupied_cells
      @occupied_cells ||= cells.flat_map { |cell|
        x = cell["x"].to_i
        y = cell["y"].to_i
        w = [cell["w"].to_i, 1].max
        h = [cell["h"].to_i, 1].max
        h.times.flat_map { |dy| w.times.map { |dx| [x + dx, y + dy] } }
      }.uniq.size
    end

    def open_cells = [(columns * rows) - occupied_cells, 0].max

    def disable_scroll? = settings["disable_scroll"] == true

    def predefined? = board.predefined?

    def published? = board.published?

    def duplicate_registration? = @duplicate_registration

    # Tiles with no picture that did not ASK to have no picture. A BLANK
    # display_image_url is the deliberate "hide pictures" marker and is not a
    # fault; nil falls through to the shared Image's art, so it is only missing
    # when that falls through to nothing too.
    def tiles_missing_art
      @tiles_missing_art ||= begin
        candidates = tiles.reject(&:picture_hidden?).select { |tile| tile.display_image_url.blank? }
        arted = image_ids_with_art(candidates.filter_map(&:image_id))

        candidates.count { |tile| !arted.include?(tile.image_id) }
      end
    end

    # Is there authored source on disk for this template? A hand-registered one
    # sits outside the re-seed loop entirely — `rake fringe_templates:seed` can
    # neither see nor heal it — which is what the Export button is for.
    def authored_source?
      return true unless kind == :fringe

      @authored_source ||= Dir.glob(Boards::FringeTemplates::SEED_DIR.join("*.obf")).any? do |path|
        JSON.parse(File.read(path))["name"].to_s.casecmp?(category.to_s)
      rescue JSON::ParserError
        false
      end
    end

    # Fringe only. A template whose category is not a key in
    # InterestCategories::KEYWORDS can never be chosen by StructurePlanner —
    # nothing routes an interest word to it — so it is a dead template that looks
    # perfectly healthy from every other angle.
    def planner_reachable?
      return true unless kind == :fringe
      return false if category.blank?

      matching_category_name.present?
    end

    # Fringe only, and per LEVEL rather than a boolean: source_for_category
    # returns :seed_set BEFORE it consults FringeTemplates, so a category that
    # ships as a page of one core set is live for levels on the other one. A
    # "School" template is dead for extended (core-84 has a School page) and live
    # for starter/standard (core-60 does not).
    def shadowing_levels
      return [] unless kind == :fringe
      return [] if category.blank?

      seed_name = Boards::StructurePlanner::CATEGORY_SEED_ALIASES[matching_category_name] || category

      Boards::StructurePlanner::LEVELS.filter_map do |level, config|
        pages = Boards::StructurePlanner::SEED_SET_PAGES[config[:core_template]] || []
        level if pages.any? { |page| page.casecmp?(seed_name) }
      end
    end

    def problems
      @problems ||= [].tap do |list|
        if displaced_tiles.positive?
          list << "#{pluralize_tiles(displaced_tiles)} stacked on a cell another tile already holds, or parked past " \
                  "the grid — every set built from this template inherits it. Use Repair layout."
        end
        list << "#{pluralize_tiles(duplicate_tiles)} duplicated." if duplicate_tiles.positive?
        list << "No tiles." if tile_count.zero?
        list << "Not predefined — the builder still clones it, but it is invisible in the catalogue." unless predefined?
        list << "Not published." unless published?
        list << "disable_scroll is off, so this grid scrolls instead of fitting one screen." unless disable_scroll?
        if tiles_missing_art.positive?
          list << "#{pluralize_tiles(tiles_missing_art)} with no picture and not marked as hidden."
        end
        unless planner_reachable?
          list << "\"#{category}\" is not a Boards::InterestCategories category, so the planner can never " \
                  "select this template."
        end
        if duplicate_registration?
          list << "More than one board is registered for \"#{category}\" — which one a build clones is undefined."
        end
      end
    end

    def notes
      @notes ||= [].tap do |list|
        if shadowing_levels.any?
          list << "\"#{category}\" ships as a page of the core seed set for #{shadowing_levels.to_sentence} builds, " \
                  "so those levels use the seed page and never clone this template."
        end
        unless authored_source?
          list << "Hand-registered — there is no .obf for it in db/seeds/board_builder_sets/fringe-pages, so a " \
                  "re-seed cannot heal it. Export it and commit the file."
        end
      end
    end

    def healthy? = problems.empty?

    def status
      return "error" unless healthy?
      return "warn" if notes.any?

      "ok"
    end

    private

    def settings = board.settings.is_a?(Hash) ? board.settings : {}

    def tiles
      @tiles ||= board.board_images.to_a
    end

    def cells
      @cells ||= tiles.filter_map { |tile| tile.layout.is_a?(Hash) ? tile.layout[AUTHORED_SCREEN] : nil }
    end

    def matching_category_name
      return @matching_category_name if defined?(@matching_category_name)

      @matching_category_name = Boards::InterestCategories.categories.find { |name| name.casecmp?(category.to_s) }
    end

    # One query per board instead of Boards::ImageResolver.art? per TILE. art? is
    # `image.docs.exists?`, which is cheap on its own and an N+1 on an index that
    # renders a dozen 40-tile templates.
    def image_ids_with_art(image_ids)
      return Set.new if image_ids.empty?

      Doc.where(documentable_type: "Image", documentable_id: image_ids.uniq)
        .distinct
        .pluck(:documentable_id)
        .to_set
    end

    def pluralize_tiles(count) = "#{count} tile#{"s" if count != 1}"
  end
end
