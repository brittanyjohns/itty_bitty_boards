# frozen_string_literal: true

# Refund helpers for the menu-board image budget.
#
# A menu build spends ONE up-front credit transaction: the flat menu_create
# extraction fee plus `reserved` x per-image cost for AI image generation.
# The reservation is stashed on the menu board at create/rerun time:
#
#   board.settings["menu_credit"] = {
#     "txn_id"    => <CreditTransaction id of the spend>,
#     "per_image" => <menu_image cost at spend time>,
#     "reserved"  => <image budget N the user picked>,
#   }
#
# These helpers give credits back when the build delivers less than was paid
# for. All are idempotent (metadata markers plus a cumulative cap against the
# original spend, computed under a lock on the spend txn) so Sidekiq retries
# and concurrent image batches can't over-refund. All fail soft: a refund
# error is logged, never raised into the calling job — the board build always
# wins over the ledger housekeeping.
module Menus
  class CreditRefunds
    class << self
      # Refund the part of the image budget that was never queued for
      # generation (items reused existing art, or the menu had fewer novel
      # items than the budget). Call once per build with the count actually
      # queued; pass 0 from a build-failure rescue to return the whole
      # image portion.
      def refund_unused!(board, queued_count)
        with_reservation(board) do |txn, res|
          unused = res["reserved"].to_i - queued_count.to_i
          next if unused <= 0
          refund!(board, txn, unused * res["per_image"].to_i, reason: "menu_images_unused")
        end
      end

      # Refund one image's cost when its OpenAI generation failed.
      def refund_failed_image!(board, image_id)
        with_reservation(board) do |txn, res|
          refund!(board, txn, res["per_image"].to_i, reason: "menu_image_failed", image_id: image_id)
        end
      end

      # The vision extraction never produced a board — the user got nothing,
      # so refund the entire spend, flat fee included (mirrors the
      # BoardScreenshotImportJob failure refund).
      def refund_all!(board, reason: "menu_extraction_failed")
        with_reservation(board) do |txn, _res|
          refund!(board, txn, txn.amount.abs, reason: reason)
        end
      end

      private

      def with_reservation(board)
        res = board&.settings&.dig("menu_credit")
        return unless res.is_a?(Hash)

        txn = CreditTransaction.find_by(id: res["txn_id"], kind: "spend")
        return unless txn

        yield txn, res
      rescue => e
        Rails.logger.error "[Menus::CreditRefunds] refund failed for board=#{board&.id}: #{e.class}: #{e.message}"
        nil
      end

      # Refund `amount` against the spend txn. The idempotency marker, the cap
      # at the original spend, and the topup-first split all live in
      # Credits::TxnRefunds — shared with the bulk-regenerate path, which
      # reserves its own spend the same way. Only the board_id context is ours.
      def refund!(board, txn, amount, reason:, image_id: nil)
        Credits::TxnRefunds.refund!(txn, amount, reason: reason, image_id: image_id,
                                                 metadata: { board_id: board.id })
      end
    end
  end
end
