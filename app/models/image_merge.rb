# One group's outcome inside an ImageMergeBatch — the ledger.
#
# `images` has no `deleted_at` (adding one would have to be honoured by every
# scope on the model), so a merged-away row is really gone. `merged_attributes`
# is a snapshot of it, and the four id arrays record exactly what moved, so a
# bad merge can be diagnosed — and undone by hand — after the fact.
#
# The unique index on (batch, group_index) is the idempotency key: a replayed
# ImageMergeJob finds this row and returns instead of merging twice.
# == Schema Information
#
# Table name: image_merges
#
#  id                   :bigint           not null, primary key
#  board_image_ids      :bigint           default([]), not null, is an Array
#  doc_ids              :bigint           default([]), not null, is an Array
#  group_index          :integer          not null
#  label                :string
#  merged_attributes    :jsonb            not null
#  reparented_board_ids :bigint           default([]), not null, is an Array
#  skip_reason          :text
#  status               :string           default("merged"), not null
#  user_doc_ids         :bigint           default([]), not null, is an Array
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  image_merge_batch_id :bigint           not null
#  merged_image_id      :bigint
#  survivor_id          :bigint
#
# Indexes
#
#  index_image_merges_on_batch_and_group       (image_merge_batch_id,group_index) UNIQUE
#  index_image_merges_on_image_merge_batch_id  (image_merge_batch_id)
#  index_image_merges_on_merged_image_id       (merged_image_id)
#  index_image_merges_on_survivor_id           (survivor_id)
#
# Foreign Keys
#
#  fk_rails_...  (image_merge_batch_id => image_merge_batches.id)
#
class ImageMerge < ApplicationRecord
  STATUSES = %w[merged skipped failed].freeze

  belongs_to :image_merge_batch

  validates :status, inclusion: { in: STATUSES }
  validates :group_index, uniqueness: { scope: :image_merge_batch_id }

  scope :merged, -> { where(status: "merged") }
  scope :skipped, -> { where(status: "skipped") }
end
