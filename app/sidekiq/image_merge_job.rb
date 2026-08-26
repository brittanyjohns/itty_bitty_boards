# Merges ONE duplicate-label group from an ImageMergeBatch plan.
#
# One group, one transaction, one ledger row. The batch fans these out so a
# 591-group run can't be a single hours-long statement, and so one bad group
# fails alone.
#
# Everything here is written on the assumption that the PLAN IS STALE. It was
# produced by a scan that may have run hours ago, against library rows that any
# admin action could have changed since. So nothing is destroyed on the
# strength of the plan alone: every row is re-checked against
# Images::DuplicateScanner's own definitions immediately before the merge, and
# anything that drifted is recorded as skipped rather than merged.
class ImageMergeJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 2

  def perform(batch_id, group_index)
    batch = ImageMergeBatch.find_by(id: batch_id)
    return unless batch

    # Kill switch. Pausing a batch stops the rest of an in-flight run without
    # having to drain the queue by hand.
    return unless batch.running?

    # Idempotency: the unique index on (batch, group_index) means a retry or a
    # double-enqueue finds its own ledger row and stops.
    return if ImageMerge.exists?(image_merge_batch_id: batch.id, group_index: group_index)

    group = batch.group_at(group_index)
    return unless group

    merge(batch, group_index, group)
  ensure
    batch&.mark_complete_if_finished!
  end

  private

  def merge(batch, group_index, group)
    survivor = Images::DuplicateScanner.candidate_scope.find_by(id: group["survivor_id"])
    if survivor.nil?
      return record_skip(batch, group_index, group, "survivor #{group['survivor_id']} is no longer a library image")
    end

    expected_key = group["key"]
    if Images::DuplicateScanner.group_key_for(survivor) != expected_key
      return record_skip(batch, group_index, group, "survivor #{survivor.id} changed label/language/part_of_speech since the scan")
    end

    losers = Array(group["loser_ids"]).filter_map do |id|
      loser = Images::DuplicateScanner.candidate_scope.find_by(id: id)
      # Already gone (a prior run, or a manual cleanup) — not an error.
      next if loser.nil?
      # Drifted out of the group: someone relabelled it, changed its part of
      # speech, or made it private. Leave it entirely alone.
      next unless Images::DuplicateScanner.group_key_for(loser) == expected_key
      next if loser.id == survivor.id

      loser
    end

    if losers.empty?
      return record_skip(batch, group_index, group, "nothing left to merge")
    end

    moved = { docs: [], board_images: [], user_docs: [], boards: [] }
    snapshots = []
    # Read before any doc moves, so "the survivor's own curated default" is
    # still distinguishable from the ones it is about to inherit.
    @survivor_default_doc_id = survivor.docs.where(current: true).order(:id).last&.id

    ActiveRecord::Base.transaction do
      losers.each do |loser|
        snapshots << loser.attributes
        moved[:docs].concat(move_docs(loser, survivor))
        moved[:user_docs].concat(move_user_docs(loser, survivor))
        moved[:boards].concat(reparent_predictive_boards(loser, survivor))
        moved[:board_images].concat(move_board_images(loser, survivor))
        merge_next_words(loser, survivor)

        # Reload so the associations we just moved off aren't still cached —
        # `dependent: :destroy` would otherwise take the survivor's own docs
        # down with it.
        loser.reload
        loser.destroy!
      end

      # Every loser's docs are now the survivor's, and each may have carried its
      # own `current: true`. That flag is the LIBRARY DEFAULT and is meant to be
      # single-valued per image — Image#display_doc resolves `docs.current.last`,
      # so several current docs leave the default arbitrary rather than curated.
      # Reconcile once, after the whole group, so the survivor keeps exactly one.
      reconcile_library_default(survivor)

      ImageMerge.create!(
        image_merge_batch_id: batch.id,
        group_index: group_index,
        status: "merged",
        survivor_id: survivor.id,
        merged_image_id: snapshots.first&.dig("id"),
        label: expected_key.first,
        merged_attributes: { "images" => snapshots },
        doc_ids: moved[:docs],
        board_image_ids: moved[:board_images],
        user_doc_ids: moved[:user_docs],
        reparented_board_ids: moved[:boards],
      )
    end
  rescue => e
    Rails.logger.error("[image-merge] batch=#{batch.id} group=#{group_index} failed: #{e.message}")
    ImageMerge.create!(
      image_merge_batch_id: batch.id,
      group_index: group_index,
      status: "failed",
      survivor_id: group["survivor_id"],
      label: Array(group["key"]).first,
      skip_reason: e.message.to_s.truncate(1000),
    )
  end

  # Docs are the whole point of merging — they're the art the survivor is
  # missing. Moved, never destroyed.
  #
  # `Doc.unscoped`, NOT `loser.docs`: Doc carries
  # `default_scope { where(deleted_at: nil) }`, so the association hides
  # soft-deleted rows. They would then be missed here AND missed by
  # `dependent: :destroy` (which walks the same scoped association), leaving
  # them pointing at an image id that no longer exists. A hidden doc is still
  # recoverable art — `docs#deleted` lists them — so it moves with the rest.
  def move_docs(loser, survivor)
    ids = Doc.unscoped.where(documentable_type: "Image", documentable_id: loser.id).pluck(:id)
    Doc.unscoped.where(id: ids).update_all(documentable_id: survivor.id, documentable_type: "Image")
    ids
  end

  # A UserDoc is one user's saved picture choice, keyed by BOTH doc_id and
  # image_id. The docs move above, so without this the image_id is left pointing
  # at a row that is about to be destroyed and the user's pick silently detaches
  # (Image#display_doc looks it up by image_id).
  def move_user_docs(loser, survivor)
    ids = UserDoc.where(image_id: loser.id).pluck(:id)
    UserDoc.where(id: ids).update_all(image_id: survivor.id)
    ids
  end

  # `has_many :predictive_boards, as: :parent, dependent: :destroy` means
  # destroying the loser would DESTROY these boards — real user-facing content.
  # Reparenting to the survivor preserves the provenance link the CLAUDE.md
  # invariant is about; `update_all` is deliberate, so Board#sync_user_parent
  # can't re-point an Image parent at a User on the way through.
  def reparent_predictive_boards(loser, survivor)
    ids = Board.where(parent_type: "Image", parent_id: loser.id).pluck(:id)
    Board.where(id: ids).update_all(parent_id: survivor.id)
    ids
  end

  # Only `image_id` moves. `display_image_url` is per-tile user content and is
  # left byte-identical — including "", the hide-pictures marker. Any tile left
  # pointing at art that died with the loser is repaired afterwards by the
  # batch's TileArtFanout sweep, which only touches URLs that no longer resolve.
  def move_board_images(loser, survivor)
    ids = BoardImage.where(image_id: loser.id).pluck(:id)
    BoardImage.where(id: ids).update_all(image_id: survivor.id)
    ids
  end

  # Keeps exactly one current doc: the survivor's own pre-existing default when
  # it still has one (a curated choice outranks an inherited one), otherwise the
  # newest inherited default. Never promotes a doc that was not already somebody's
  # default — an image with no current doc keeps none, and the backfill/admin
  # panel is where that gets decided deliberately.
  def reconcile_library_default(survivor)
    current_ids = survivor.docs.where(current: true).order(:id).pluck(:id)
    return if current_ids.size <= 1

    keeper = @survivor_default_doc_id if current_ids.include?(@survivor_default_doc_id)
    keeper ||= current_ids.last

    survivor.docs.where(current: true).where.not(id: keeper).update_all(current: false)
    keeper
  end

  def merge_next_words(loser, survivor)
    words = Array(loser.next_words)
    return if words.empty?

    combined = (Array(survivor.next_words) + words).uniq
    return if combined == Array(survivor.next_words)

    survivor.update_columns(next_words: combined)
  end

  def record_skip(batch, group_index, group, reason)
    Rails.logger.info("[image-merge] batch=#{batch.id} group=#{group_index} skipped: #{reason}")
    ImageMerge.create!(
      image_merge_batch_id: batch.id,
      group_index: group_index,
      status: "skipped",
      survivor_id: group["survivor_id"],
      label: Array(group["key"]).first,
      skip_reason: reason,
    )
  end
end
