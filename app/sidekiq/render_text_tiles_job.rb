# The bulk "Set text image" render: ONE job for a whole selection, instead of
# one job per tile.
#
# Two reasons it isn't just N RenderTextTileJobs. The queue only runs three
# workers, so a select-all on a 30-tile board used to park everyone else's
# single-tile render behind thirty Chrome forks. And running the selection in
# one process is what lets Images::TextTile::Creator's digest dedupe pay off
# within the batch: the first tile of a given render creates the Doc, and every
# later tile with the same digest finds it and shares the blob — no second fork.
#
# Sequential on purpose. Rendering the selection in parallel would race the
# dedupe lookup and fork Chrome N times for the same picture, which is the
# thing this exists to stop.
#
# One bad tile must not cost the other twenty-nine, so each is rescued
# individually and only marked failed itself. The batch still raises at the end
# so Sidekiq retries it — cheap, because every tile that succeeded now dedupes
# to its own Doc on the second pass rather than re-rendering.
class RenderTextTilesJob
  include Sidekiq::Job
  sidekiq_options queue: :text_images, retry: 2, backtrace: true

  # entries: [[board_image_id, options_hash], ...]
  def perform(entries)
    boards = {}
    failures = []

    Array(entries).each do |entry|
      board_image_id, options_hash = entry
      board_image = BoardImage.find_by(id: board_image_id)
      next unless board_image

      board = board_image.board
      boards[board.id] = board if board

      begin
        options = Images::TextTile::Options.from_params((options_hash || {}).symbolize_keys)

        Images::TextTile::Creator.call(
          board_image: board_image,
          user: board&.user,
          options: options,
          broadcast: false,
        )
      rescue => e
        Rails.logger.error("[text-tile] batch render failed for BoardImage #{board_image_id}: #{e.message}")
        board_image.update_column(:status, "failed")
        failures << board_image_id
      end
    end

    boards.each_value(&:broadcast_board_update!)

    raise "text tile batch failed for board_images #{failures.join(", ")}" if failures.any?
  end
end
