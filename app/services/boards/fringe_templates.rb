module Boards
  module FringeTemplates
    SEED_DIR = Rails.root.join("db/seeds/board_builder_sets/fringe-pages")
    TEMPLATE_MARKER = "fringe_template_category"
    # Which core set this template is sized for. A fringe page is cloned into an
    # authored grid and must match it — Core 60 pages are 10 wide, Core 84 pages
    # 12 — so one template per category cannot serve both levels.
    VARIANT_MARKER = "fringe_template_core_template"
    # Authored in the .obf itself rather than inferred from the directory, so the
    # admin "New from .obf" paste goes through seed_data! with the same authority
    # a file has. The directory is organizational; a spec asserts the two agree.
    VARIANT_KEY = "ext_saw_core_template"
    VARIANTS = %w[core-60 core-84].freeze
    # The authored grid width of each core set's pages. A fringe page is cloned
    # into that grid and Boards::NavRowSync only widens the clone's lg count —
    # it never moves a tile — so a template of the wrong width renders with dead
    # columns. Kept here rather than re-derived from the seed .obf files so the
    # admin register form can refuse a mismatch without parsing anything.
    EXPECTED_COLUMNS = { "core-60" => 10, "core-84" => 12 }.freeze

    module_function

    # Ordered by :id so the winner is the OLDEST row rather than whatever the
    # planner happens to be handed — the same rule Boards::RobustSets.all_roots
    # follows. Two boards on one category AND variant is a fault the admin
    # registry reports; until it is cleaned up, at least every build clones the
    # same one.
    #
    # Resolution order, widest-to-narrowest fallback:
    #
    #   1. the template authored for this core set
    #   2. a template carrying no variant at all — hand-registered, or seeded
    #      before variants existed, so it is the best guess available
    #   3. the OTHER variant, as a last resort
    #
    # Step 3 is deliberate: a grid that needs repacking still beats falling
    # through to :ai_generated, which charges the user credits for a page we
    # already have authored. Boards::TemplateHealth flags the missing variant so
    # the gap is visible rather than silently absorbed.
    def find(category_name, core_template: nil)
      return nil if category_name.blank?

      scope = all_for(category_name)
      return scope.first if core_template.blank?

      for_variant(scope, core_template).first ||
        for_variant(scope, nil).first ||
        scope.first
    end

    # Every admin-owned board registered for a category, across variants.
    def all_for(category_name)
      return Board.none if category_name.blank?

      Board.where(user_id: admin_id)
        .where("LOWER(settings->>'#{TEMPLATE_MARKER}') = ?", category_name.to_s.strip.downcase)
        .order(:id)
    end

    # Narrow an all_for scope to one variant. `nil` selects the rows carrying no
    # variant marker at all, which is how a pre-variant or hand-registered
    # template stays reachable.
    def for_variant(scope, core_template)
      if core_template.blank?
        scope.where("settings->>'#{VARIANT_MARKER}' IS NULL")
      else
        scope.where("LOWER(settings->>'#{VARIANT_MARKER}') = ?", core_template.to_s.strip.downcase)
      end
    end

    def all_templates
      Board.where(user_id: admin_id)
        .where("settings->>'#{TEMPLATE_MARKER}' IS NOT NULL")
        .order(:name, :id)
    end

    def category_for(board)
      board.settings.to_h[TEMPLATE_MARKER].presence
    end

    # nil for a template that predates variants or was hand-registered — callers
    # must treat that as "unknown", never as a particular core set.
    def core_template_for(board)
      board.settings.to_h[VARIANT_MARKER].presence
    end

    # Every authored source on disk, nested one directory per core set.
    def seed_files
      return [] unless SEED_DIR.exist?

      Dir.glob(SEED_DIR.join("**", "*.obf")).sort
    end

    def seed_all!
      results = []
      seed_files.each do |path|
        results << seed_obf!(path)
      end
      results.compact
    end

    def seed_obf!(path)
      seed_data!(JSON.parse(File.read(path)))
    end

    # The same seed pass, from already-parsed OBF data. Split out so an admin
    # creating a template from a pasted .obf goes through the IDENTICAL code path
    # as the rake task reading a file off disk — including the destructive
    # prune — rather than a second, drifting implementation.
    def seed_data!(obf_data)
      category = obf_data["name"]
      variant = normalize_variant(obf_data[VARIANT_KEY])

      admin_user = User.find_by(id: admin_id)
      raise "Admin user (#{admin_id}) not found" unless admin_user

      board, _dynamic_data = Board.from_obf(
        obf_data, admin_user, nil,
        import_options: {
          apply_button_attributes: true,
        },
      )
      return nil unless board

      markers = { TEMPLATE_MARKER => category.downcase, "disable_scroll" => true }
      markers[VARIANT_MARKER] = variant if variant

      board.update!(
        predefined: true,
        published: true,
        settings: (board.settings || {}).merge(markers),
      )

      prune_removed_tiles!(board, obf_data)
      board
    end

    def normalize_variant(value)
      normalized = value.to_s.strip.downcase
      VARIANTS.include?(normalized) ? normalized : nil
    end

    def prune_removed_tiles!(board, obf_data)
      keep = Array(obf_data["buttons"]).map { |b| b["label"].to_s.strip.downcase }
      board.board_images.includes(:image).find_each do |bi|
        label = (bi.image&.label || bi.label).to_s.strip.downcase
        bi.destroy unless keep.include?(label)
      end
    end

    def admin_id
      User::DEFAULT_ADMIN_ID
    end
  end # module FringeTemplates
end
