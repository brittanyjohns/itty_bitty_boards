module API
  module V1
    # Board Builder wizard endpoint (standalone — NOT part of MySpeak onboarding).
    #
    #   GET  /api/v1/board_builder/templates  -> picker catalog (no auth-sensitive data)
    #   POST /api/v1/board_builder            -> build a linked board set for a communicator
    #
    # Flow: BlueprintAssembler turns {template, interests} into a builder-ready
    # blueprint, BoardTreeBuilder persists the linked tree and attaches the root
    # to the communicator, and we stash the normalized interests on the
    # communicator so the wizard can be re-run / pre-filled.
    #
    # Re-run guard (issue #269): if the communicator already has a builder set,
    # create returns HTTP 409 `board_builder_set_exists` instead of silently
    # duplicating it; the client re-sends with `confirm=true` to build another.
    class BoardBuilderController < API::ApplicationController
      # Label-only template catalog for the picker grid.
      def templates
        render json: { templates: Boards::StarterBlueprints.catalog }, status: :ok
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
                 status: :unprocessable_entity
          return
        end

        # Re-run guard (issue #269): if this communicator already has a builder
        # set, don't silently stack a second favorited root. Warn so the frontend
        # can confirm; `confirm=true` is the explicit "build another" opt-in.
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
        #  - a seeded "robust vocabulary set" (Core 60/84) -> deep-clone the
        #    seeded set and route interests into the cloned fringe pages;
        #  - a hardcoded starter template (home/daily_routine) -> assemble a
        #    label blueprint and build a fresh linked tree.
        robust_root = Boards::RobustSets.find_root(params[:template])

        if robust_root
          cloner = Boards::SeededSetCloner.new(
            robust_root, communicator: communicator,
            interests: params[:interests], favorite_root: true,
          )
          root = cloner.call
          interests = cloner.interests
        else
          assembler = Boards::BlueprintAssembler.new(
            template:  params[:template],
            interests: params[:interests],
            user:      current_user,
          )
          blueprint = assembler.call

          root = Boards::BoardTreeBuilder.new(
            blueprint, communicator: communicator, favorite_root: true,
          ).call
          interests = assembler.interests
        end

        # Persist the normalized interests for re-runs (jsonb merge, non-destructive).
        communicator.update!(details: (communicator.details || {}).merge("interests" => interests))

        render json: root.api_view(current_user), status: :created
      rescue Boards::BlueprintAssembler::UnknownTemplate => e
        Rails.logger.warn "[BoardBuilder] #{e.message}"
        render json: { error: "unknown_template",
                       message: "That template isn't available. Pick one from the list and try again." },
               status: :unprocessable_entity
      rescue Boards::BoardTreeBuilder::BuildError, Boards::SeededSetCloner::CloneError => e
        Rails.logger.warn "[BoardBuilder] build failed: #{e.message}"
        render json: { error: "build_failed",
                       message: "Something went wrong building the board set — your info is safe, give it another try." },
               status: :unprocessable_entity
      rescue StandardError => e
        # Last-resort guard: never leak an internal error (or a 500) to the
        # client. Core symbols now self-heal, so this should be rare.
        Rails.logger.error "[BoardBuilder] unexpected error: #{e.class}: #{e.message}"
        render json: { error: "build_failed",
                       message: "Something went wrong building the board set — your info is safe, give it another try." },
               status: :unprocessable_entity
      end
    end
  end
end
