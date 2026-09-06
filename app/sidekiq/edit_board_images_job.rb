# Bulk "Edit pictures with a prompt": one paid OpenAI image EDIT (img2img) per
# selected tile, against the art that tile is already showing.
#
# Sibling of GenerateImagesJob, and the credit shape is the same: the caller
# pre-paid per image against one spend txn and hands it here, so a tile that
# fails gives its own cost back. It is a separate job rather than a loop over
# EditBoardImageJob because that one reports no per-image outcome — it swallows
# its own failures — which makes a per-image refund impossible.
class EditBoardImagesJob
  include Sidekiq::Job
  # retry: 0, matching EditBoardImageJob. A retry re-runs a PAID edit against
  # art the first attempt may already have replaced, so the second run edits
  # its own output.
  sidekiq_options queue: :ai_images, retry: 0, backtrace: true

  # Marker for a refunded failed edit. Distinct from the generation path's
  # "image_generation_failed" — different feature, different spend txn.
  REFUND_REASON = "image_edit_failed"

  # The per-tile rescues below refund a failure as it happens; this covers the
  # job dying outright, so tiles that never got their turn are still refunded.
  # Ones already refunded in-loop hit the idempotency marker and cost nothing.
  sidekiq_retries_exhausted do |msg, _ex|
    board_id, board_image_ids, _prompt, _transparent, options = msg["args"]
    options = (options || {}).with_indifferent_access
    txn = Credits::TxnRefunds.spend_txn(options[:credit_txn_id])
    per_image = options[:credit_per_image].to_i
    next unless txn && per_image.positive?

    unfinished = BoardImage.where(id: board_image_ids).where.not(status: "edited").pluck(:id)
    unfinished.each do |board_image_id|
      Credits::TxnRefunds.refund!(txn, per_image, reason: REFUND_REASON,
                                                  image_id: board_image_id,
                                                  metadata: { board_id: board_id })
    end
  end

  # `options["credit_txn_id"]` / `options["credit_per_image"]` — the spend this
  # batch was pre-paid against. Absent for an admin run, which spends nothing;
  # Credits::TxnRefunds no-ops on a nil txn, so no branch is needed for that.
  def perform(board_id, board_image_ids, prompt, transparent_bg = false, options = {})
    options = (options || {}).with_indifferent_access
    txn = Credits::TxnRefunds.spend_txn(options[:credit_txn_id])
    per_image = options[:credit_per_image].to_i

    board = Board.find_by(id: board_id)
    board_images = BoardImage.where(board_id: board_id, id: board_image_ids)
    return if board.nil? || board_images.empty?

    board_images.each do |board_image|
      begin
        # Re-resolved rather than trusted from the controller: the tile could
        # have had its picture hidden between enqueue and now, and editing art
        # a tile is no longer showing would silently un-hide it.
        if board_image.edit_source_image_url(board.user).blank?
          fail_image!(board_image, txn, per_image, board_id, "no picture to edit")
          next
        end

        # Returns nil rather than raising on failure — it rescues internally.
        if board_image.create_image_edit!(prompt, transparent_bg).blank?
          fail_image!(board_image, txn, per_image, board_id, "edit returned nothing")
          next
        end

        board_image.update_column(:status, "edited")
      rescue => e
        Rails.logger.error(
          ["**** IMAGE EDIT ERROR ****", "BoardImage ID: #{board_image.id}",
           "Board ID: #{board_id}", e.message, *e.backtrace].join("\n")
        )
        fail_image!(board_image, txn, per_image, board_id, e.message)
        next
      end
    end

    # The editor is open on the other end of this; without it the new art only
    # appears on a manual reload.
    board.broadcast_board_update!
  end

  private

  def fail_image!(board_image, txn, per_image, board_id, reason)
    Rails.logger.error "EditBoardImagesJob: BoardImage #{board_image.id} failed — #{reason}"
    board_image.update_column(:status, "error")
    return unless txn && per_image.positive?

    Credits::TxnRefunds.refund!(txn, per_image, reason: REFUND_REASON,
                                                image_id: board_image.id,
                                                metadata: { board_id: board_id })
  end
end
