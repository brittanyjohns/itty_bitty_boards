# Nightly net under Board#enqueue_preview_for_public_board.
#
# The hook fires the moment a board joins the public catalogue — which for every
# catalogue seeder is BEFORE it has a single tile, because they save the board
# published and add tiles afterwards. It logs the deferral and returns; this is
# what picks the board up once its tiles exist. It also heals boards published
# before the hook shipped, which is the #871 backlog itself: 9 of 67 boards on
# /api/public_boards had never had a render enqueued at all.
#
# Selection is by OUTCOME (`Board.missing_public_preview`), not by provenance,
# so it covers every path that can ever mint a catalogue board without knowing
# any of them exist.
class PublicBoardPreviewSweepJob
  include Sidekiq::Job
  # queue: maintenance — operator housekeeping must never starve tile audio or
  # a render somebody is watching. The renders it enqueues run on :default like
  # every other cover.
  #
  # retry: 0 — the work is idempotent and the sweep runs again tomorrow, so a
  # retry can only double-enqueue Grover renders for the same boards.
  sidekiq_options retry: 0, queue: :maintenance

  # Each enqueue is a headless-Chrome page render. A cap keeps an unexpected
  # backlog (a bulk publish, a scope change) draining over nights instead of
  # landing on the queue in one burst; read at call time so it retunes from
  # Hatchbox without a deploy.
  DEFAULT_MAX_PER_RUN = 25

  def self.max_per_run
    ENV.fetch("PUBLIC_BOARD_PREVIEW_SWEEP_MAX_PER_RUN", DEFAULT_MAX_PER_RUN).to_i
  end

  def perform
    scope = Board.missing_public_preview.order(:id)
    total = scope.count

    if total.zero?
      Rails.logger.info("PublicBoardPreviewSweepJob: no public boards missing a cover")
      return 0
    end

    limit = self.class.max_per_run
    boards = limit.positive? ? scope.limit(limit).to_a : scope.to_a

    enqueued = boards.count do |board|
      board.run_generate_preview_job
      true
    rescue => e
      # One bad row must not abandon the rest of the sweep. Named, because a
      # board that silently keeps failing to enqueue is exactly the state this
      # job exists to make visible.
      Rails.logger.error(
        "PublicBoardPreviewSweepJob: enqueue failed for board #{board.id}: #{e.class}: #{e.message}"
      )
      false
    end

    Rails.logger.info(
      "PublicBoardPreviewSweepJob: enqueued #{enqueued} of #{total} public board(s) missing a cover " \
      "(ids: #{boards.map(&:id).join(", ")})"
    )
    if total > boards.size
      Rails.logger.warn(
        "PublicBoardPreviewSweepJob: #{total - boards.size} public board(s) still missing a cover after this run " \
        "(cap #{limit} per run) — they are picked up by the next sweep"
      )
    end

    enqueued
  end
end
