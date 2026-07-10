module API
  module V1
    class BoardBuilderController < API::ApplicationController
      RECOMMENDED_SMALL_SET = "core-60"
      RECOMMENDED_LARGE_SET = "core-84"

      COMPLEXITY_LEVELS = [
        { key: "starter", name: "Starter",
          description: "A focused set with essential categories — great for beginning communicators.",
          fringe_page_range: "4-6",
          grid_rows: 6, grid_columns: 10 },
        { key: "standard", name: "Standard",
          description: "A solid vocabulary foundation with a good range of categories.",
          fringe_page_range: "8-10",
          grid_rows: 6, grid_columns: 10 },
        { key: "extended", name: "Extended",
          description: "A full vocabulary set with broad category coverage.",
          fringe_page_range: "10-15",
          grid_rows: 7, grid_columns: 12 },
      ].freeze

      def templates
        glp_catalog = Boards::GlpTemplates.catalog

        # `?template_type=glp` narrows the picker to GLP templates only. Omit it
        # for the full (backward-compatible) catalog.
        if params[:template_type].to_s.downcase == "glp"
          glp_template, glp_reason = recommend_glp_template
          render json: {
            templates: glp_catalog,
            glp_templates: glp_catalog,
            recommended_template: glp_template,
            recommendation_reason: glp_reason,
          }, status: :ok
          return
        end

        catalog = Boards::StarterBlueprints.catalog
        recommended_tmpl, tmpl_reason = recommend_template(catalog)
        level_rec = recommend_level
        glp_template, glp_reason = recommend_glp_template

        render json: {
          levels: COMPLEXITY_LEVELS,
          recommended_level: level_rec&.dig(:key),
          # A GLP-stage communicator gets the gestalt recommendation; otherwise
          # fall back to the existing level/template reasons.
          recommendation_reason: glp_reason || level_rec&.dig(:reason) || tmpl_reason,
          templates: catalog + glp_catalog,
          glp_templates: glp_catalog,
          recommended_template: glp_template || recommended_tmpl,
        }, status: :ok
      end

      def interest_categories
        categories = Boards::InterestCategories::KEYWORDS.map do |name, words|
          { name: name, words: words.sort }
        end.sort_by { |c| c[:name] }

        render json: { categories: categories,
                       max_interests: Boards::InterestWords::MAX_INTERESTS },
               status: :ok
      end

      def create
        communicator = current_user.communicator_accounts.find_by(id: params[:communicator_id])
        unless communicator
          render json: { error: "communicator_not_found",
                         message: "We couldn't find that communicator on your account." },
                 status: :not_found
          return
        end

        # Existing-set handling runs BEFORE the group-limit check so a user at
        # their board-set cap can still REPLACE (destroying frees the slot the
        # rebuild consumes). Three paths on an existing set:
        #   replace=true — destroy every builder set on this communicator
        #                  (cascade via the builder BoardGroup), then build
        #   confirm=true — stack another set (legacy behavior, kept for
        #                  backward compat: old clients send it and silently
        #                  repurposing it to "replace" would destroy data)
        #   neither      — 409 so the client can offer both options
        existing_roots = communicator.builder_roots.to_a
        if existing_roots.any?
          if params[:replace].to_s == "true"
            destroy_existing_builder_sets!(existing_roots)
          elsif params[:confirm].to_s != "true"
            existing = existing_roots.first
            render json: { error: "board_builder_set_exists",
                           message: "You already built a board set for this communicator. Replace it or build another?",
                           existing_root_id: existing.id,
                           existing_root_name: existing.name,
                           built_at: existing.created_at,
                           can_replace: true,
                           existing_sets: existing_roots.map { |r|
                             { root_id: r.id, name: r.name, built_at: r.created_at }
                           } },
                   status: :conflict
            return
          end
        end

        # A builder set is a Board Set (BoardGroup), so it counts against the
        # board-SET cap, not the per-board cap. Exactly one group slot, zero
        # board slots (see User#countable_board_count / #countable_board_group_count).
        if current_user.reload.at_board_group_limit?
          render json: { error: "You've reached your plan's board set limit (#{current_user.countable_board_group_count}/#{current_user.board_group_limit}). Upgrade to add more.",
                         limit: current_user.board_group_limit,
                         count: current_user.countable_board_group_count },
                 status: :unprocessable_content
          return
        end

        # Resolve the build key: `level` (new) or `template` (legacy).
        build_key = resolve_build_key
        root_name = resolve_root_name(build_key)

        owner = communicator.owner || communicator.user
        raise Boards::BoardTreeBuilder::BuildError, "communicator has no owning user" unless owner

        raw_interests = params[:interests]
        interests  = Boards::InterestWords.normalize_list(raw_interests)
        categories = Boards::InterestWords.extract_categories(raw_interests)

        root = nil
        board_group = nil
        ActiveRecord::Base.transaction do
          root = Board.new(name: root_name, user: owner)
          root.board_type = "dynamic"
          root.assign_parent
          root.voice = VoiceService.normalize_voice(communicator.voice)
          root.generate_unique_slug
          root.settings = (root.settings || {}).merge("builder_root" => true)
          root.status = "building_board"
          root.save!

          child_board = communicator.child_boards.create!(board: root, created_by_id: owner.id)
          child_board.update!(favorite: true)

          # The builder set's canonical container. Member boards (root + every
          # child the job builds) attach here; this is what the user's board-set
          # limit counts and what cascade-deletes the whole tree. Add the root
          # now; the job attaches the rest. (BoardGroup#set_root_board nulls
          # root_board_id on create when the group has no boards yet, so pin it
          # after the join exists.)
          board_group = owner.board_groups.create!(name: root_name, builder: true)
          board_group.board_group_boards.create!(board: root, position: 0)
          board_group.update!(root_board_id: root.id)

          communicator.update!(details: (communicator.details || {}).merge("interests" => interests))
        end

        BuildBoardSetJob.perform_async(root.id, communicator.id, build_key, interests, categories,
                                       { "include_phrases" => include_phrases_param,
                                         "board_group_id" => board_group.id })

        render json: serialize_built_root(root), status: :created
      rescue Boards::BlueprintAssembler::UnknownTemplate => e
        Rails.logger.warn "[BoardBuilder] #{e.message}"
        render json: { error: "unknown_template",
                       message: "That template isn't available. Pick one from the list and try again." },
               status: :unprocessable_content
      rescue Boards::BoardTreeBuilder::BuildError, Boards::SeededSetCloner::CloneError => e
        Rails.logger.warn "[BoardBuilder] build failed: #{e.message}"
        render json: { error: "build_failed",
                       message: "Something went wrong building the board set — your info is safe, give it another try." },
               status: :unprocessable_content
      rescue StandardError => e
        Rails.logger.error "[BoardBuilder] unexpected error: #{e.class}: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
        root.update_column(:status, "failed") if defined?(root) && root&.persisted?
        render json: { error: "build_failed",
                       message: "Something went wrong building the board set — your info is safe, give it another try." },
               status: :unprocessable_content
      end

      private

      # Destroy every existing builder set on the communicator ahead of a
      # replace=true rebuild. Routes through the builder BoardGroup so the
      # #407 cascade takes the whole tree (members + ChildBoards + joins); a
      # group-less root (legacy/corrupt data) is destroyed directly. Runs in
      # its own transaction, deliberately NOT the one that creates the new
      # root — the build finishes async in BuildBoardSetJob, so a combined
      # transaction wouldn't protect against a failed build anyway, and
      # holding one across a ~15-board cascade risks lock contention. If the
      # rebuild fails, a re-run finds no existing set and builds fresh.
      def destroy_existing_builder_sets!(roots)
        ActiveRecord::Base.transaction do
          roots.each do |root|
            if (group = root.builder_board_group)
              group.destroy!
            else
              root.destroy!
            end
          end
        end
      end

      def resolve_build_key
        if params[:level].present?
          level = params[:level].to_s.downcase
          unless Boards::StructurePlanner::LEVELS.key?(level)
            raise Boards::BlueprintAssembler::UnknownTemplate,
                  "unknown level #{params[:level].inspect}"
          end
          level
        elsif params[:template].present?
          template = params[:template].to_s
          robust_root  = Boards::RobustSets.find_root(template)
          # GLP slugs are NO LONGER a build target — gestalts ride every build
          # as the integrated Phrases layer (see build_with_structure_planner).
          # GLP templates remain in the catalog for recommendation display only.
          starter_tree = robust_root ? nil : Boards::StarterBlueprints.tree_for(template)
          if robust_root.nil? && starter_tree.nil?
            raise Boards::BlueprintAssembler::UnknownTemplate,
                  "unknown template #{template.inspect}"
          end
          template
        else
          raise Boards::BlueprintAssembler::UnknownTemplate,
                "level or template is required"
        end
      end

      # Tri-state opt-in for the gestalt Phrases layer: nil (param absent) =>
      # default-on in the planner; true/false honors the wizard toggle. A
      # communicator with a glp_stage always gets the layer regardless.
      def include_phrases_param
        return nil unless params.key?(:include_phrases)

        ActiveModel::Type::Boolean.new.cast(params[:include_phrases])
      end

      def resolve_root_name(build_key)
        if Boards::StructurePlanner::LEVELS.key?(build_key)
          core_template = Boards::StructurePlanner::LEVELS[build_key][:core_template]
          robust_root = Boards::RobustSets.find_root(core_template)
          robust_root&.name || "Communication Board"
        else
          robust_root = Boards::RobustSets.find_root(build_key)
          robust_root&.name ||
            Boards::GlpTemplates.find_board(build_key)&.name ||
            Boards::StarterBlueprints.tree_for(build_key)&.dig(:name) ||
            "Communication Board"
        end
      end

      def recommend_template(catalog)
        return [nil, nil] if params[:communicator_id].blank?

        communicator = current_user.communicator_accounts.find_by(id: params[:communicator_id])
        profile = CommunicatorProfile.for(communicator: communicator)
        return [nil, nil] unless profile

        if profile.young? || profile.emerging?
          slug = RECOMMENDED_SMALL_SET
          reason = "A smaller core vocabulary is a good starting point for young or emerging communicators."
        else
          slug = RECOMMENDED_LARGE_SET
          reason = "A larger core vocabulary gives this communicator more room to grow."
        end
        return [nil, nil] unless catalog.any? { |t| t[:key] == slug }

        [slug, reason]
      end

      # Stage-appropriate GLP template recommendation for the requested
      # communicator. Returns [slug, reason] when the communicator has a
      # glp_stage AND a matching template board is actually seeded; nil
      # otherwise (no communicator, no stage, or unseeded environment).
      def recommend_glp_template
        return nil if params[:communicator_id].blank?

        communicator = current_user.communicator_accounts.find_by(id: params[:communicator_id])
        return nil unless communicator

        stage = CommunicatorProfile.for(communicator: communicator)&.glp_stage
        return nil if stage.blank?

        slug = Boards::GlpTemplates.recommended_for(stage)
        return nil if slug.blank? || !Boards::GlpTemplates.boards.exists?(slug: slug)

        [slug, "Recommended for gestalt language processors at NLA Stage #{stage}."]
      end

      def recommend_level
        return nil if params[:communicator_id].blank?

        communicator = current_user.communicator_accounts.find_by(id: params[:communicator_id])
        profile = CommunicatorProfile.for(communicator: communicator)
        return nil unless profile

        if profile.young? || profile.emerging?
          { key: "starter", reason: "A focused starter set is a great beginning for #{communicator.name}." }
        elsif profile.developing? || profile.young_teen?
          { key: "standard", reason: "A solid vocabulary foundation for #{communicator.name}." }
        else
          { key: "extended", reason: "#{communicator.name} is ready for a full vocabulary set." }
        end
      end

      def serialize_built_root(root)
        root.api_view(current_user)
      rescue StandardError => e
        Rails.logger.warn "[BoardBuilder] api_view failed for board #{root.id}, returning minimal payload: #{e.class}: #{e.message}"
        { id: root.id, board_id: root.id, name: root.name, slug: root.slug,
          board_type: root.board_type, user_id: root.user_id, status: root.status }
      end
    end
  end
end
