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

        if current_user.at_board_limit?
          render json: { error: "Maximum number of boards reached (#{current_user.countable_board_count}/#{current_user.board_limit}). Please upgrade to add more." },
                 status: :unprocessable_content
          return
        end

        existing = communicator.board_builder_root
        if existing && params[:confirm].to_s != "true"
          render json: { error: "board_builder_set_exists",
                         message: "You already built a board set for this communicator. Build another?",
                         existing_root_id: existing.id,
                         existing_root_name: existing.name,
                         built_at: existing.created_at },
                 status: :conflict
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

          communicator.update!(details: (communicator.details || {}).merge("interests" => interests))
        end

        BuildBoardSetJob.perform_async(root.id, communicator.id, build_key, interests, categories,
                                       { "include_phrases" => include_phrases_param })

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
