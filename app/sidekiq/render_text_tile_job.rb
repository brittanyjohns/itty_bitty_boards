# Renders a text tile picture. See Images::TextTile::Creator.
#
# Its own queue, not :ai_images — a text render takes about a second and must
# not sit behind a queue of minute-long OpenAI calls, which is the whole
# difference the user feels between this and the paid styles.
class RenderTextTileJob
  include Sidekiq::Job
  sidekiq_options queue: :text_images, retry: 2, backtrace: true

  def perform(board_image_id, options_hash = {})
    board_image = BoardImage.find_by(id: board_image_id)
    return unless board_image

    options = Images::TextTile::Options.from_params((options_hash || {}).symbolize_keys)

    Images::TextTile::Creator.call(
      board_image: board_image,
      user: board_image.board&.user,
      options: options,
    )
  rescue => e
    Rails.logger.error("[text-tile] render failed for BoardImage #{board_image_id}: #{e.message}")
    board_image&.update_column(:status, "failed")
    raise
  end
end
