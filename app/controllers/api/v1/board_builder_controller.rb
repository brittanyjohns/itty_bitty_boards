module API
  module V1
    # Board Builder wizard endpoint (standalone — NOT part of MySpeak onboarding).
    #
    #   GET  /api/v1/board_builder/templates  -> picker catalog (no auth-sensitive data)
    #   POST /api/v1/board_builder            -> build a linked board set for a communicator
    #
    # Flow (async, same rails as GenerateBoardJob): every synchronous pre-check
    # stays in-request, then we create JUST the root board (status
    # "building_board"), attach it to the communicator (ChildBoard + favorite,
    # so the set appears immediately in "building" state), stash the normalized
    # interests for re-runs, enqueue BuildBoardSetJob to build everything else
    # (fringe boards, tiles, links, interest routing, AI art), and return 201
    # with the root payload right away. The frontend polls GET /api/boards/:id
    # until status flips to "complete" (or "failed").
    #
    # Re-run guard (issue #269): if the communicator already has a builder set,
    # create returns HTTP 409 `board_builder_set_exists` instead of silently
    # duplicating it; the client re-sends with `confirm=true` to build another.
    class BoardBuilderController < API::ApplicationController
      # Robust-set slugs used for the server-side template recommendation.
      # These are the keys vocab_sets:seed stamps on the seeded roots; the
      # recommendation is only emitted when the slug is actually in the
      # catalog (i.e. seeded in this environment).
      RECOMMENDED_SMALL_SET = "core-60"
      RECOMMENDED_LARGE_SET = "core-84"

      # Label-only template catalog for the picker grid. With an optional
      # communicator_id (scoped to the caller's own communicators), a stored
      # profile yields a server-side template recommendation: young/emerging
      # communicators get the smaller core set, everyone else the larger one.
      def templates
        catalog = Boards::StarterBlueprints.catalog
        recommended, reason = recommend_template(catalog)
        render json: { templates: catalog,
                       recommended_template: recommended,
                       recommendation_reason: reason },
               status: :ok
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

        # A wizard run persists a linked tree but counts as ONE board (the root;
        # sub-boards are marked builder_child). So gate on current state — block
        # only when the user is already at/over their limit.
        if current_user.at_board_limit?
          render json: { error: "Maximum number of boards reached (#{current_user.countable_board_count}/#{current_user.board_limit}). Please upgrade to add more." },
                 status: :unprocessable_content
          return
        end

        # Re-run guard (issue #269): if this communicator already has a builder
        # set, don't silently stack a second favorited root. Warn so the frontend
        # can confirm; `confirm=true` is the explicit "build another" opt-in.
        #
        # Async note (#271): a root that's still building (status
        # "building_board") — or one whose job failed (status "failed") — DOES
        # count as "an existing set" here, deliberately. While a build is in
        # flight it stops a concurrent double-build; after a failure the root is
        # the user-visible failure artifact and `confirm=true` is the explicit
        # "build another" path. The guard can't trip on its OWN root because the
        # root is created below, after this check.
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

        # Two build paths share the same guards/response shape:
        #  - a seeded "robust vocabulary set" (Core 60/84) -> BuildBoardSetJob
        #    deep-clones the seeded set into the pre-created root;
        #  - a hardcoded starter template (home/daily_routine) -> the job
        #    assembles a label blueprint and builds the linked tree under it.
        # Resolve the template synchronously so an unknown key still 422s
        # in-request — only the heavy build moves to the job.
        robust_root  = Boards::RobustSets.find_root(params[:template])
        starter_tree = robust_root ? nil : Boards::StarterBlueprints.tree_for(params[:template])
        if robust_root.nil? && starter_tree.nil?
          raise Boards::BlueprintAssembler::UnknownTemplate,
                "unknown template #{params[:template].inspect}"
        end

        owner = communicator.owner || communicator.user
        raise Boards::BoardTreeBuilder::BuildError, "communicator has no owning user" unless owner

        raw_interests = params[:interests]
        interests  = Boards::InterestWords.normalize_list(raw_interests)
        categories = Boards::InterestWords.extract_categories(raw_interests)
        root_name  = robust_root ? robust_root.name : starter_tree[:name]

        # Create the root in-request so the 201 payload (and the duplicate
        # guard, and the board-limit count) see it immediately; the job adopts
        # it and fills in the rest. ChildBoard attach + favorite stay in-request
        # too, so the set appears on the communicator right away — in
        # "building" state.
        root = nil
        ActiveRecord::Base.transaction do
          root = Board.new(name: root_name, user: owner)
          root.board_type = "dynamic" # builder roots link child folders
          root.assign_parent          # => parent is the owning User
          root.voice = VoiceService.normalize_voice(communicator.voice)
          root.generate_unique_slug
          # Same markers the builders set: root is countable + re-run
          # detectable; status drives the frontend polling page.
          root.settings = (root.settings || {}).merge("builder_root" => true)
          root.status = "building_board"
          root.save!

          child_board = communicator.child_boards.create!(board: root, created_by_id: owner.id)
          child_board.update!(favorite: true)

          # Persist the normalized interests for re-runs (jsonb merge, non-destructive).
          communicator.update!(details: (communicator.details || {}).merge("interests" => interests))
        end

        # Credits: the Board Builder charges NO AI credits in-request (there is
        # no check_credits! gate on this endpoint — compare scenarios/menus).
        # The only credit-adjacent work is AI art for novel interest words,
        # which was ALREADY queued asynchronously (GenerateImagesJob) and is
        # paid where it always was. So there is nothing to refund if
        # BuildBoardSetJob fails — no refund path needed, by decision.
        BuildBoardSetJob.perform_async(root.id, communicator.id, params[:template].to_s, interests, categories)

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
        # Last-resort guard: never leak an internal error (or a 500) to the
        # client. Core symbols now self-heal, so this should be rare.
        # If the root already committed (e.g. the enqueue itself raised), don't
        # strand it in "building_board" — mark it failed so the duplicate guard
        # offers the normal confirm-to-rebuild path instead of a stuck spinner.
        # Backtrace included because a message alone has proven too thin to
        # locate post-commit failures (e.g. an image_processing tempfile race).
        Rails.logger.error "[BoardBuilder] unexpected error: #{e.class}: #{e.message}\n#{e.backtrace&.first(15)&.join("\n")}"
        root.update_column(:status, "failed") if defined?(root) && root&.persisted?
        render json: { error: "build_failed",
                       message: "Something went wrong building the board set — your info is safe, give it another try." },
               status: :unprocessable_content
      end

      private

      # [recommended_template_key, reason] for the optional communicator_id
      # param, or [nil, nil] when there's no usable stored profile (or the
      # recommended set isn't seeded in this environment). Ownership-scoped:
      # someone else's communicator id resolves to nil and is ignored.
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

      # Board#api_view walks images/attachments and can trip on transient
      # ActiveStorage/variant races. By this point the root is committed and
      # BuildBoardSetJob is enqueued — failing the request here would report a
      # false failure for a build that's running (and the rescue below would
      # mark it "failed" out from under the job). Degrade to a minimal payload
      # instead; the frontend polls GET /api/boards/:id for the full view.
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
