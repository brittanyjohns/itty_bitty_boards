module Admin
  # Registry + health for the Board Builder's SEED MATERIAL: the standalone fringe
  # page templates and the Core 60/84 robust vocab sets. Both are ordinary boards
  # owned by User::DEFAULT_ADMIN_ID, told apart only by markers in `settings`, and
  # until this screen existed the only way to see or change any of it was a Rails
  # console plus a rake task.
  #
  # Tile work happens in the real board editor — this page links out to it rather
  # than rebuilding a grid editor here.
  #
  # Three rails are load-bearing:
  #
  #   1. The ROBUST markers are never written here. Boards::RobustSets decides
  #      which board IS the Core 60/84 seed from two settings keys, so a
  #      "mark this board as the root" button re-opens the door that
  #      `rake board_builder:unmark_stray_vocab_roots` exists to close. The only
  #      supported way to become a root stays VocabSets.seed_slug! from authored
  #      source. Strays are reported read-only.
  #
  #   2. Unregistering a fringe template clears `predefined` alongside the
  #      marker. `Board.not_builder_seed` keys on that marker and is the ONLY
  #      thing keeping an admin-owned, published, predefined board out of
  #      `Board.public_boards` — dropping the marker alone publishes it to the
  #      gallery. `published` is deliberately left alone: unpublishing is the
  #      marketplace-protection raise path and it breaks /pb/<slug> for any sheet
  #      already printed.
  #
  #   3. index performs NO writes. Board#open_grid_cells looks like the right way
  #      to report grid fullness and is not — it opens with update_board_layout,
  #      which saves the board and every tile. Boards::TemplateHealth computes the
  #      same numbers read-only.
  class BoardBuilderTemplatesController < Admin::ApplicationController
    before_action :require_seed_admin!, except: %i[index]
    before_action :set_board, only: %i[show unregister repair_layout export]

    def index
      load_registry
    end

    def show
      @kind = template_kind(@board)
      return redirect_to(admin_dashboard_board_builder_templates_path,
                         alert: "That board is not a Board Builder template.") unless @kind

      @slug = Boards::RobustSets.slug_for(@board)
      @health = health_for(@board, @kind)
      @set_pages = @kind == :robust_root ? robust_page_health(@slug) : []
      @tiles = @board.board_images.includes(:image).order(:position)
    end

    def new
      @obf_raw = nil
    end

    # Author a fringe template directly from a pasted .obf — the same authored
    # format the files in db/seeds/board_builder_sets/fringe-pages carry, so a
    # template can be created with its exact grid and part_of_speech colours in one
    # step rather than tile by tile in the editor.
    #
    # It goes through Boards::FringeTemplates.seed_data!, the IDENTICAL pass the
    # rake task runs on a file — including the destructive prune — so a
    # hand-created template cannot drift from a seeded one.
    #
    # The board created here has no file under SEED_DIR, so `rake
    # fringe_templates:seed` can neither see nor heal it. That is what Export is
    # for: download the .obf and commit it into the seed directory. The registry
    # flags such a template as "hand-registered" until you do.
    def create
      @obf_raw = params[:obf].to_s.strip
      parsed = parse_obf(@obf_raw)
      return render(:new, status: :unprocessable_entity) if @error

      if (@error = authored_template_error(parsed))
        return render(:new, status: :unprocessable_entity)
      end

      board = Boards::FringeTemplates.seed_data!(parsed)
      unless board
        @error = "That .obf produced no board."
        return render(:new, status: :unprocessable_entity)
      end

      redirect_to admin_dashboard_board_builder_template_path(board),
                  notice: "Created the #{parsed["name"]} fringe template. Commit the .obf into " \
                          "db/seeds/board_builder_sets/fringe-pages so a re-seed can heal it."
    end

    # Turn an existing admin-owned board into a fringe page template. This is how
    # a NEW template is added: build the board in /admin/board_builds (which
    # already drafts a word list, previews the symbol art, and creates it owned by
    # the seed admin), then register it here.
    def register
      board = Board.find_by(id: params[:board_id])
      category = params[:category].to_s.strip

      if (@error = registration_error(board, category))
        load_registry
        return render(:index, status: :unprocessable_entity)
      end

      board.update!(
        predefined: true,
        published: true,
        settings: (board.settings || {}).merge(
          Boards::FringeTemplates::TEMPLATE_MARKER => category.downcase,
          # Registration LOCKS the board to one screen, which is a real change to
          # how it renders. The form says so before you click.
          "disable_scroll" => true,
        ),
      )

      redirect_to admin_dashboard_board_builder_templates_path,
                  notice: "“#{board.name}” is now the fringe template for #{category}."
    end

    def unregister
      if @board.settings.is_a?(Hash) && @board.settings[Boards::RobustSets::ROOT_MARKER]
        return redirect_to admin_dashboard_board_builder_templates_path,
                           alert: "“#{@board.name}” is a seeded vocab-set root. Its marker is the set's identity " \
                                  "and is only ever written by a re-seed — see rake board_builder:unmark_stray_vocab_roots."
      end

      category = @board.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER]
      @board.update!(
        predefined: false,
        settings: @board.settings.to_h.except(Boards::FringeTemplates::TEMPLATE_MARKER),
      )

      redirect_to admin_dashboard_board_builder_templates_path,
                  notice: "“#{@board.name}” is no longer the #{category} template. Builds now pay for an " \
                          "AI-generated page for that category instead."
    end

    def repair_layout
      if Boards::RobustSets.slug_for(@board).present?
        ActiveRecord.after_all_transactions_commit do
          RepairBoardBuilderTemplateJob.perform_async(@board.id)
        end
        return redirect_to admin_dashboard_board_builder_templates_path,
                           notice: "Repairing “#{@board.name}” and its pages in the background."
      end

      removed = Boards::TileDeduper.collapse_duplicates!(@board)
      moved = Boards::LayoutRepacker.unstack!(@board)

      redirect_to admin_dashboard_board_builder_template_path(@board),
                  notice: "Repaired “#{@board.name}”: removed #{removed} duplicate tile(s), " \
                          "moved #{moved} displaced tile(s)."
    end

    # The authored .obf for this board, so an edit made in the board editor can be
    # committed to db/seeds/ instead of being reverted by the next re-seed.
    def export
      exporter = Boards::SeedSourceExporter.new(@board)
      send_data exporter.to_json_document,
                filename: exporter.filename,
                type: "application/json",
                disposition: "attachment"
    end

    def reseed_fringe
      basename = params[:file].presence

      if basename && !available_fringe_files.include?(File.basename(basename))
        return redirect_to admin_dashboard_board_builder_templates_path,
                           alert: "No authored fringe source named #{File.basename(basename)}."
      end

      ActiveRecord.after_all_transactions_commit do
        SeedBoardBuilderTemplatesJob.perform_async("fringe", basename && File.basename(basename))
      end

      redirect_to admin_dashboard_board_builder_templates_path,
                  notice: "Re-seeding #{basename || "every fringe template"} from db/seeds in the background."
    end

    def reseed_vocab_set
      slug = params[:slug].to_s

      unless VocabSets.available_slugs.include?(slug)
        return redirect_to admin_dashboard_board_builder_templates_path,
                           alert: "No authored source for #{slug.presence || "that set"}."
      end

      ActiveRecord.after_all_transactions_commit do
        SeedBoardBuilderTemplatesJob.perform_async("vocab", slug)
      end

      redirect_to admin_dashboard_board_builder_templates_path,
                  notice: "Re-seeding #{Boards::RobustSets.display_name_for(slug)} in the background. " \
                          "This takes a few minutes."
    end

    private

    def require_seed_admin!
      return if seed_admin

      redirect_to admin_root_path, alert: "No default admin user configured — cannot manage builder templates."
    end

    def seed_admin
      @seed_admin ||= User.find_by(id: User::DEFAULT_ADMIN_ID)
    end

    # Member :id is always a board id, resolved through the seed admin's boards so
    # a hand-edited id can never reach an unrelated user's board.
    def set_board
      @board = Board.where(user_id: User::DEFAULT_ADMIN_ID).find_by(id: params[:id])
      return if @board

      redirect_to admin_dashboard_board_builder_templates_path, alert: "Template not found."
    end

    def load_registry
      @fringe = fringe_health
      @sets = robust_set_health
      @stray_roots = stray_robust_roots
      @uncovered_categories = uncovered_categories
      @missing_sets = VocabSets.available_slugs - @sets.map { |row| row[:slug] }
      @unseeded_fringe_files = unseeded_fringe_files
    end

    def fringe_health
      Boards::FringeTemplates.all_templates.includes(board_images: :image).map do |board|
        category = board.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER]
        {
          board: board,
          category: category,
          health: Boards::TemplateHealth.new(
            board, kind: :fringe, category: category,
            duplicate_registration: Boards::FringeTemplates.all_for(category).count > 1,
          ),
        }
      end
    end

    def robust_set_health
      Boards::RobustSets.all_roots.includes(board_images: :image).map do |root|
        slug = Boards::RobustSets.slug_for(root)
        {
          root: root,
          slug: slug,
          # The SET's name is a property of the slug, never the seed row's name —
          # a renamed seed must not rename every user's board.
          set_name: Boards::RobustSets.display_name_for(slug),
          source_present: VocabSets.available_slugs.include?(slug.to_s),
          page_count: Boards::RobustSets.set_boards(slug).count,
          health: Boards::TemplateHealth.new(root, kind: :robust_root, slug: slug),
        }
      end
    end

    def robust_page_health(slug)
      Boards::RobustSets.set_boards(slug).includes(board_images: :image).map do |board|
        Boards::TemplateHealth.new(board, kind: :robust_page, slug: slug)
      end
    end

    def health_for(board, kind)
      category = board.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER]
      Boards::TemplateHealth.new(
        board, kind: kind, category: category,
        slug: Boards::RobustSets.slug_for(board),
        duplicate_registration: kind == :fringe && Boards::FringeTemplates.all_for(category).count > 1,
      )
    end

    def template_kind(board)
      settings = board.settings.to_h
      return :robust_root if settings[Boards::RobustSets::ROOT_MARKER]
      return :fringe if settings[Boards::FringeTemplates::TEMPLATE_MARKER]

      :robust_page if board.obf_id.present? && robust_slugs.any? { |slug| board.obf_id.start_with?("#{slug}:") }
    end

    def robust_slugs
      @robust_slugs ||= Boards::RobustSets.all_roots.filter_map { |root| Boards::RobustSets.slug_for(root) }
    end

    # Boards carrying the root marker that all_roots cannot see — a clone made
    # before the marker was stripped on clone, or a row that lost `predefined`.
    # Reported READ-ONLY: `rake board_builder:unmark_stray_vocab_roots` also
    # reports which built sets took a stray's name, and that doesn't fit a button.
    def stray_robust_roots
      visible = Boards::RobustSets.all_roots.pluck(:id)
      Board.where("COALESCE((boards.settings->>'#{Boards::RobustSets::ROOT_MARKER}')::boolean, false)")
        .where.not(id: visible)
        .order(:id)
        .limit(50)
    end

    # Categories the planner knows but nothing covers — no core seed page and no
    # fringe template — so a build pays AI credits for them. This is the list that
    # says where authoring a template saves money.
    def uncovered_categories
      seed_pages = Boards::StructurePlanner::SEED_SET_PAGES.values.flatten.map(&:downcase)

      Boards::InterestCategories.categories.reject do |category|
        seed_name = Boards::StructurePlanner::CATEGORY_SEED_ALIASES[category] || category
        seed_pages.include?(seed_name.downcase) || Boards::FringeTemplates.find(category).present?
      end
    end

    def available_fringe_files
      @available_fringe_files ||= Dir.glob(Boards::FringeTemplates::SEED_DIR.join("*.obf")).map { |p| File.basename(p) }.sort
    end

    # Authored .obf files with no template row here — the "you never ran the seed
    # task" state, which otherwise reads as "we only have 3 templates".
    def unseeded_fringe_files
      registered = Boards::FringeTemplates.all_templates.filter_map do |board|
        board.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER].to_s.downcase
      end

      available_fringe_files.reject do |file|
        name = JSON.parse(File.read(Boards::FringeTemplates::SEED_DIR.join(file)))["name"].to_s.downcase
        registered.include?(name)
      rescue JSON::ParserError
        true
      end
    end

    # Admin-owned boards an admin could plausibly register: not already seed
    # material, not a builder child, not a menu board.
    def registerable_boards
      @registerable_boards ||= Board.where(user_id: User::DEFAULT_ADMIN_ID)
        .not_builder_seed
        .not_builder_child
        .where.not(parent_type: "Menu")
        .order(updated_at: :desc)
        .limit(200)
    end

    def selectable_categories
      Boards::InterestCategories.categories
    end

    # @obf_raw holds the SUBMITTED text so a parse error re-renders what was typed
    # rather than an empty box — the Admin::KitPagesController#assign_content rule.
    def parse_obf(raw)
      if raw.blank?
        @error = "Paste the .obf document."
        return nil
      end

      parsed = JSON.parse(raw)
      unless parsed.is_a?(Hash)
        @error = "An .obf is a JSON object — it starts with { and ends with }."
        return nil
      end

      parsed
    rescue JSON::ParserError => e
      @error = "That isn't valid JSON: #{e.message.truncate(160)}"
      nil
    end

    def authored_template_error(obf)
      category = obf["name"].to_s.strip
      return "The .obf needs a \"name\" — it is the category this template serves." if category.blank?
      return "The .obf needs an \"id\". Board.from_obf upserts on it, so without one a re-seed forks a second board." if obf["id"].to_s.strip.blank?
      return "The .obf needs a \"buttons\" array." unless obf["buttons"].is_a?(Array) && obf["buttons"].any?

      unless selectable_categories.any? { |name| name.casecmp?(category) }
        return "\"#{category}\" is not a Boards::InterestCategories category, so the planner could never select it. " \
               "Set the .obf's \"name\" to one of: #{selectable_categories.to_sentence}."
      end

      if (existing = Boards::FringeTemplates.find(category))
        return "#{category} is already served by \u201C#{existing.name}\u201D. Unregister that one first."
      end

      nil
    end

    def registration_error(board, category)
      return "Pick a board to register." if board.nil?
      # FringeTemplates.find is scoped to the seed admin, so a marker on anyone
      # else's board is one nothing can ever read.
      return "Only boards owned by the seed admin can be templates." unless board.user_id == User::DEFAULT_ADMIN_ID
      return "Pick a category." if category.blank?

      unless selectable_categories.any? { |name| name.casecmp?(category) }
        # source_for_category only ever reaches :prebuilt for a category the
        # planner already produces, so a free-text category authors a template
        # the wizard can never select.
        return "“#{category}” is not a Boards::InterestCategories category, so the planner could never select it."
      end

      if (existing = Boards::FringeTemplates.find(category))
        return "#{category} is already served by “#{existing.name}”. Unregister that one first."
      end

      if Boards::LayoutRepacker.unstack_screen!(board, "lg", dry_run: true).positive?
        # Registering sets disable_scroll, which locks the board to one screen; a
        # stacked cell there reads as a free cell a build will then spend.
        return "“#{board.name}” has tiles stacked on the same cell. Repair its layout before registering it."
      end

      nil
    end

    # Same host rule as Admin::KitPagesController#kit_preview_url — one place that
    # knows where the frontend lives.
    def frontend_host
      (ENV["FRONT_END_URL"].presence || "https://app.speakanyway.com").chomp("/")
    end

    def board_editor_url(board) = "#{frontend_host}/boards/#{board.id}/edit"
    def board_layout_url(board) = "#{frontend_host}/boards/#{board.id}/edit/layout"
    def board_speak_url(board) = "#{frontend_host}/boards/#{board.id}"

    helper_method :registerable_boards, :selectable_categories,
                  :board_editor_url, :board_layout_url, :board_speak_url
  end
end
