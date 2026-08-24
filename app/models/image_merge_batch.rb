# One bulk library-dedupe run.
#
# Modelled on AdminBoardBuild, and for the same reason: the expensive, hard to
# reverse half of the work is a fan-out of Sidekiq jobs, so the operator needs a
# durable record to review BEFORE it runs and to watch while it does.
#
# The load-bearing rail is the same one the board builder has: **scanning writes
# nothing**. `plan` is produced by Images::DuplicateScanner, a pure read. A batch
# only ever leaves `planned` because someone explicitly applied it.
# == Schema Information
#
# Table name: image_merge_batches
#
#  id            :bigint           not null, primary key
#  error_message :text
#  filters       :jsonb            not null
#  plan          :jsonb            not null
#  report        :jsonb            not null
#  status        :string           default("planned"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  created_by_id :bigint
#
# Indexes
#
#  index_image_merge_batches_on_created_by_id  (created_by_id)
#  index_image_merge_batches_on_status         (status)
#
class ImageMergeBatch < ApplicationRecord
  STATUSES = %w[planned running paused complete failed].freeze

  has_many :image_merges, dependent: :destroy
  belongs_to :created_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def planned? = status == "planned"
  def running? = status == "running"
  def paused? = status == "paused"
  def complete? = status == "complete"
  def failed? = status == "failed"

  # The groups the scanner found, each { "key" => [label, language, pos],
  # "survivor_id" => Integer, "loser_ids" => [Integer, ...] }.
  def groups = Array(plan["groups"])

  def group_at(index) = groups[index]

  def mark_running! = update!(status: "running", error_message: nil)
  def mark_paused! = update!(status: "paused")

  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(1000))
  end

  # Called by each ImageMergeJob as it finishes. The batch is done when every
  # group has a ledger row — merged or skipped.
  def mark_complete_if_finished!
    return false unless running?
    return false unless image_merges.count >= groups.size

    update!(status: "complete")
    true
  end

  def summary
    {
      groups: groups.size,
      redundant_rows: groups.sum { |g| Array(g["loser_ids"]).size },
      merged: image_merges.where(status: "merged").count,
      skipped: image_merges.where(status: "skipped").count,
      failed: image_merges.where(status: "failed").count,
    }
  end
end
