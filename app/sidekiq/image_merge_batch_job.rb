# Fans an ImageMergeBatch plan out into one ImageMergeJob per group.
#
# Enqueue-only: it does no merging itself, so a huge batch costs one short job
# here and the real work is spread across the maintenance queue where it can be
# paused, retried, and starved by anything user-facing.
class ImageMergeBatchJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 1

  def perform(batch_id)
    batch = ImageMergeBatch.find_by(id: batch_id)
    return unless batch
    # Only a planned batch may start. A paused one is resumed by an explicit
    # re-apply, which flips it back to running first.
    return unless batch.planned? || batch.paused?

    groups = batch.groups
    if groups.empty?
      batch.update!(status: "complete")
      return
    end

    batch.mark_running!

    # `perform_async` hits Redis immediately and the worker reads on its own
    # connection, so a job pushed from inside the transaction that wrote the
    # batch can dequeue before the commit and find nothing. mark_running! above
    # is its own transaction, but wrapping is free outside one and is the
    # convention this codebase holds to.
    ActiveRecord.after_all_transactions_commit do
      groups.each_index do |index|
        # Already done on a previous run — don't re-enqueue a no-op.
        next if ImageMerge.exists?(image_merge_batch_id: batch.id, group_index: index)

        ImageMergeJob.perform_async(batch.id, index)
      end
    end
  rescue => e
    Rails.logger.error("[image-merge-batch] #{batch_id} failed to fan out: #{e.message}")
    batch&.mark_failed!(e.message)
    raise e
  end
end
