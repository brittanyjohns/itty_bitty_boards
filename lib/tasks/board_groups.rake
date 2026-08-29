namespace :board_groups do
  # Backfill for issue #409 (follow-up to #407). Before #407, a Board Builder
  # run persisted a whole linked tree but NO BoardGroup — "set-ness" lived in
  # the root board's settings["builder_root"] JSONB marker, the root counted as
  # a board, and deleting the root orphaned its children. #407 made new builds
  # write a real `builder: true` BoardGroup (root + every predictive child as
  # board_group_boards) so the set is a real Board Set and cascade-deletes as a
  # unit. (Board Sets carried their own cap back then; since #796 the boards
  # inside a set are what count, and group membership affects no limit at all.)
  #
  # Existing builder sets in prod predate that and have no BoardGroup. This task
  # wraps each `builder_root` tree that lacks a builder BoardGroup into one,
  # exactly mirroring the controller/BuildBoardSetJob construction:
  #   BoardGroup(builder: true, root_board_id: root, user: root.user, name: root.name)
  #   + board_group_boards for the root and its predictive_board_id descendants
  #     (BFS bounded to MAX_DEPTH = 2 — root + 2 levels — matching
  #     Boards::BoardTreeBuilder / SeededSetCloner, scoped to the owner's boards
  #     so a tile pointing at a shared board can't pull it into the sweep).
  #
  # Idempotent: a root that already has a builder BoardGroup (root_board_id
  # match) is skipped, so re-runs create no duplicate groups or join rows.
  #
  # Logs each user's countable_board_group_count before/after. There is no
  # over-limit report any more: Board Sets are uncapped since #796, so wrapping
  # existing trees into groups can't push anyone over anything.
  #
  # APPLIES BY DEFAULT. Preview with DRY_RUN=1 (per the deploy ordering in #409:
  # run --dry-run, review what it would wrap, then run for real). Scope to one
  # owner with USER_ID=N:
  #   DRY_RUN=1 rake board_groups:backfill_builder_sets        # preview all
  #   rake board_groups:backfill_builder_sets                  # apply all
  #   DRY_RUN=1 USER_ID=740 rake board_groups:backfill_builder_sets
  desc "Wrap existing Board Builder trees into builder BoardGroups (DRY_RUN=1 to preview; USER_ID=N to scope)"
  task backfill_builder_sets: :environment do
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase.strip)

    roots = Board.where("(boards.settings ->> 'builder_root') = 'true'")
    roots = roots.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    # Only builder roots that don't already have a builder BoardGroup.
    pending = roots.find_all do |root|
      next false unless root.user_id
      !BoardGroup.builder.exists?(root_board_id: root.id)
    end

    skipped = roots.count - pending.size
    by_user = pending.group_by(&:user_id)

    puts "#{dry_run ? '[DRY RUN] ' : ''}Backfilling builder BoardGroups for #{pending.size} root(s) " \
         "across #{by_user.size} user(s). (#{skipped} root(s) already wrapped — skipped.)"

    # Per-user board-set count BEFORE any of their roots are wrapped.
    before_counts = by_user.keys.index_with do |uid|
      BoardGroup.where(user_id: uid, predefined: [false, nil]).count
    end

    created_groups = 0
    attached_boards = 0

    by_user.each do |uid, user_roots|
      user_roots.each do |root|
        member_ids = builder_set_board_ids(root)

        if dry_run
          puts "  [DRY RUN] would wrap root ##{root.id} #{root.name.inspect} (owner #{uid}): " \
               "new builder group + #{member_ids.size} board(s)."
        else
          ActiveRecord::Base.transaction do
            owner = root.user
            group = owner.board_groups.create!(name: root.name, builder: true)
            # set_root_board nulls root_board_id on create (the group has no
            # boards yet), so attach the root first, then pin it — mirrors the
            # controller. Children follow at sequential positions.
            group.board_group_boards.create!(board_id: root.id, position: 0)
            group.update!(root_board_id: root.id)
            (member_ids - [root.id]).each_with_index do |bid, i|
              group.board_group_boards.create!(board_id: bid, position: i + 1)
            end
          end
        end

        created_groups += 1
        attached_boards += member_ids.size
      end
    end

    # Per-user before/after. Board Sets are uncapped (#796), so there is nothing
    # to flag here — this is telemetry for the backfill, not a limit report.
    puts "\nPer-user board-set counts (countable_board_group_count):"
    by_user.each do |uid, user_roots|
      user = User.find(uid)
      before = before_counts[uid]
      after = dry_run ? before + user_roots.size : user.countable_board_group_count
      puts "  user ##{uid} (#{user.plan_type || 'free'}): #{before} -> #{after}"
    end

    puts "\n#{dry_run ? '[DRY RUN] would create' : 'Created'} #{created_groups} builder " \
         "BoardGroup(s); #{attached_boards} board(s) attached."

    puts "\nDry run only — re-run without DRY_RUN to apply." if dry_run
  end

  # Sets created before BoardGroup#seed_display_images! existed have member
  # boards whose display_image_url is blank and whose preview hasn't been
  # rendered — they show as broken thumbnails on the set page. Seed each from
  # its own tiles and pin the set's cover by reference. Idempotent: anything
  # that already resolves an image is left alone.
  #
  #   DRY_RUN=1 rake board_groups:backfill_display_images   # preview
  #   rake board_groups:backfill_display_images             # apply
  #   USER_ID=740 rake board_groups:backfill_display_images # scope to one owner
  desc "Seed missing display images on board sets and their member boards (DRY_RUN=1 to preview; USER_ID=N to scope)"
  task backfill_display_images: :environment do
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase.strip)

    groups = BoardGroup.all
    groups = groups.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    seeded_boards = 0
    seeded_groups = 0

    groups.find_each do |group|
      missing = group.boards.reject { |board| board.display_image_url.present? }
      needs_cover = group.cover_board_id.blank? && group.read_attribute(:display_image_url).blank?
      next if missing.empty? && !needs_cover

      if dry_run
        puts "set ##{group.id} #{group.name.inspect}: #{missing.size} board(s) without an image" \
             "#{needs_cover ? ', no cover' : ''}"
        next
      end

      seeded_boards += missing.count(&:seed_display_image_from_tiles!)
      seeded_groups += 1 if group.seed_display_images!
    end

    puts "Seeded #{seeded_boards} board image(s) and #{seeded_groups} set cover(s)."
    puts "Dry run only — re-run without DRY_RUN to apply." if dry_run
  end
end

# Every board in a builder set: BFS the predictive_board_id links from the root,
# bounded to MAX_DEPTH levels and scoped to the owner's own boards. Mirrors
# Boards::BoardTreeBuilder::MAX_DEPTH (2) and BuildBoardSetJob#set_board_ids so
# the backfill attaches exactly the boards a fresh build would.
def builder_set_board_ids(root, max_depth = 2)
  owner_id = root.user_id
  seen = [root.id]
  frontier = [root.id]
  depth = 0

  while frontier.any? && depth < max_depth
    child_ids = BoardImage.where(board_id: frontier)
                          .where.not(predictive_board_id: nil)
                          .pluck(:predictive_board_id).uniq
    children = Board.where(id: child_ids, user_id: owner_id).where.not(id: seen).pluck(:id)
    break if children.empty?

    seen.concat(children)
    frontier = children
    depth += 1
  end

  seen
end
