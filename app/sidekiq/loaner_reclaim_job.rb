# Daily reclaim sweep for loaner communicators (B5 — issue #161).
#
# A loaner whose claim link was sent more than RECLAIM_AFTER ago without
# being claimed is reclaimed: the account flips back to `sandbox`, the
# passcode is cleared, and the SLP's slot is freed.
#
# The loaner_started_at fallback handles legacy loaners (or ones never
# given a claim link) so a stranded loaner doesn't rot a slot forever.
class LoanerReclaimJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3

  RECLAIM_AFTER = ENV.fetch("LOANER_RECLAIM_AFTER_DAYS", 90).to_i.days

  def perform
    cutoff = Time.current - RECLAIM_AFTER
    reclaimed = 0

    ChildAccount.loaner.where(claimed_at: nil).find_each do |account|
      anchor = account.claim_token_sent_at || account.loaner_started_at || account.created_at
      next if anchor.nil? || anchor > cutoff

      account.reclaim!(reason: "expired_90d")
      reclaimed += 1
    rescue => e
      Rails.logger.error "[LoanerReclaimJob] failed to reclaim ChildAccount #{account.id}: #{e.message}"
    end

    Rails.logger.info "[LoanerReclaimJob] reclaimed=#{reclaimed} cutoff=#{cutoff.iso8601}"
    reclaimed
  end
end
