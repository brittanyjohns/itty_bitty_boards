# frozen_string_literal: true

# Idempotent refunds against a credit SPEND transaction.
#
# A feature that pre-pays for N units of async work (menu image budgets, bulk
# image regeneration) has to be able to give a unit back when that unit fails.
# This is the arithmetic all of those share; the *lookup* of which txn a given
# feature reserved stays with the feature (see Menus::CreditRefunds).
#
# Three properties every caller depends on:
#
#   * Idempotent on (txn, reason, image_id) — a Sidekiq retry replaying the
#     same failure refunds once. Callers that pre-pay per image MUST pass
#     `image_id`, or the first refund marks the whole reason as done and every
#     later failure in the same spend is silently swallowed.
#   * Capped — the sum of all refunds against a spend can never exceed it,
#     recomputed under `txn.with_lock` so concurrent batches of one spend
#     can't race past the cap.
#   * Fail-soft — a refund error is logged, never raised into the calling job.
#     Ledger housekeeping must not turn a successful generation into a retry.
module Credits
  class TxnRefunds
    class << self
      # The spend txn `txn_id` names, or nil when it doesn't exist / isn't a spend.
      def spend_txn(txn_id)
        return nil if txn_id.blank?
        CreditTransaction.find_by(id: txn_id, kind: "spend")
      end

      # Refund `amount` against `txn`. Returns the amount actually refunded (0
      # when the marker already exists, the cap is reached, or anything goes
      # wrong). `metadata` is merged into the refund row — pass the caller's
      # own context (e.g. board_id) there.
      #
      # Refunds return topup credits first: spend! drains plan first, so topup
      # was the last money taken.
      def refund!(txn, amount, reason:, image_id: nil, metadata: {})
        return 0 unless txn
        return 0 if amount.to_i <= 0

        txn.with_lock do
          refunds = CreditTransaction.where(kind: "refund")
            .where("metadata ->> 'refund_for_txn' = ?", txn.id.to_s)

          marker = refunds.where("metadata ->> 'refund_reason' = ?", reason)
          marker = marker.where("metadata ->> 'image_id' = ?", image_id.to_s) if image_id
          next 0 if marker.exists?

          already_refunded = refunds.sum(:amount).to_i
          amount = [amount.to_i, txn.amount.abs - already_refunded].min
          next 0 if amount <= 0

          meta = metadata.merge(refund_for_txn: txn.id, refund_reason: reason)
          meta[:image_id] = image_id if image_id

          topup_spent = txn.metadata["from_topup"].to_i
          topup_refunded = refunds.where(source: "topup").sum(:amount).to_i
          to_topup = [amount, [topup_spent - topup_refunded, 0].max].min
          to_plan = amount - to_topup

          user = txn.user
          CreditService.refund!(user, amount: to_topup, feature_key: txn.feature_key, source: "topup", metadata: meta) if to_topup.positive?
          CreditService.refund!(user, amount: to_plan, feature_key: txn.feature_key, source: "plan", metadata: meta) if to_plan.positive?
          amount
        end
      rescue => e
        Rails.logger.error "[Credits::TxnRefunds] refund failed for txn=#{txn&.id}: #{e.class}: #{e.message}"
        0
      end
    end
  end
end
