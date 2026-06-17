# app/sidekiq/build_board_set_job.rb
#
# Async half of the Board Builder (POST /api/v1/board_builder). The controller
# does every synchronous pre-check (404 / 422 board-limit / 409 duplicate-set),
# creates the ROOT board with status "building_board", attaches it to the
# communicator (ChildBoard + favorite), and enqueues this job. This job builds
# everything else under that pre-created root:
#
#   - fringe/sub boards + their tiles
#   - predictive_board_id folder links
#   - interest -> category routing (+ a "My Favorites" fringe for leftovers)
#   - AI-art queuing for novel interest words (GenerateImagesJob)
#
# Status lifecycle mirrors GenerateBoardJob: the ROOT (and only the root)
# carries the generation status — "building_board" -> "complete", or "failed"
# on any raise (then re-raise so Sidekiq retries once). Child boards keep
# their normal defaults; the frontend polls only the root.
#
# Mid-build failure safety: both build services (Boards::SeededSetCloner and
# Boards::BoardTreeBuilder) wrap their persistence in a single transaction, so
# a failure rolls back every child board/tile and leaves just the root, marked
# "failed" — the user-visible failure artifact, same as single-board
# generation. (Blueprint-path Image rows created during label resolution may
# survive a rollback; that matches today's in-request behavior and images are
# user-scoped, reusable records — not orphans.)
class BuildBoardSetJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(root_board_id, communicator_id, template, interests = [], categories = {})
    root = Board.find_by(id: root_board_id)
    unless root
      Rails.logger.error "BuildBoardSetJob: Board with ID #{root_board_id} not found."
      return
    end

    # Retry guard — don't double-build. The build is transactional, so a
    # retried failure finds a bare root and rebuilds cleanly; but if a previous
    # attempt's transaction committed (e.g. the process died between commit and
    # the status update), the root already has tiles. Treat that as built.
    if root.status == "complete" || root.board_images.exists?
      root.update_column(:status, "complete")
      return
    end

    communicator = ChildAccount.find_by(id: communicator_id)
    unless communicator
      Rails.logger.error "BuildBoardSetJob: ChildAccount with ID #{communicator_id} not found for Board ID #{root_board_id}."
      root.update_column(:status, "failed")
      return
    end

    begin
      robust_root = Boards::RobustSets.find_root(template)

      explicit_categories = categories.is_a?(Hash) ? categories : {}

      if robust_root
        Boards::SeededSetCloner.new(
          robust_root, communicator: communicator,
          interests: interests, root: root,
          explicit_categories: explicit_categories,
        ).call
      else
        owner = communicator.owner || communicator.user
        assembler = Boards::BlueprintAssembler.new(
          template:  template,
          interests: interests,
          user:      owner,
          explicit_categories: explicit_categories,
        )
        blueprint = assembler.call

        Boards::BoardTreeBuilder.new(
          blueprint, communicator: communicator, root: root,
        ).call
      end

      root.update_column(:status, "complete")
    rescue => e
      Rails.logger.error "\n**** SIDEKIQ - BuildBoardSetJob #{root.id} #{template.inspect} \n\nERROR **** \n#{e.message}\n#{e.backtrace&.join("\n")}\n"
      root.update_column(:status, "failed")
      raise
    end
  end
end
