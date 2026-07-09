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

      # Refund `amount` against the spend txn. `reason` (+ image_id) is the
      # idempotency marker — the same reason/image pair never refunds twice —
      # and the sum of all refunds is capped at the original spend amount.
      # Refunds return topup credits first: spend! drains plan first, so
      # topup was the last money taken.
      def refund!(board, txn, amount, reason:, image_id: nil)
        return if amount <= 0

        txn.with_lock do
          refunds = CreditTransaction.where(kind: "refund")
            .where("metadata ->> 'refund_for_txn' = ?", txn.id.to_s)

          marker = refunds.where("metadata ->> 'refund_reason' = ?", reason)
          marker = marker.where("metadata ->> 'image_id' = ?", image_id.to_s) if image_id
          next if marker.exists?

          already_refunded = refunds.sum(:amount).to_i
          amount = [amount, txn.amount.abs - already_refunded].min
          next if amount <= 0

          meta = { board_id: board.id, refund_for_txn: txn.id, refund_reason: reason }
          meta[:image_id] = image_id if image_id

          topup_spent = txn.metadata["from_topup"].to_i
          topup_refunded = refunds.where(source: "topup").sum(:amount).to_i
          to_topup = [amount, [topup_spent - topup_refunded, 0].max].min
          to_plan = amount - to_topup

          user = txn.user
          CreditService.refund!(user, amount: to_topup, feature_key: txn.feature_key, source: "topup", metadata: meta) if to_topup.positive?
          CreditService.refund!(user, amount: to_plan, feature_key: txn.feature_key, source: "plan", metadata: meta) if to_plan.positive?
        end
      end
    end
  end
end
