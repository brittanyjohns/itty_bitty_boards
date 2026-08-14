# Finds admin Board Builder boards that no build owns.
#
# `Boards::AdminBuilder::Build` used to claim its set AFTER the transaction that
# created it, so a failure in the window between (two art queries and a jsonb
# write) left the boards committed with `admin_board_builds.board_id` still
# blank. BuildAdminBoardJob is `retry: 2`, so the retry rebuilt the whole set —
# root and every page — and the first set was stranded: published, in no build's
# `art_report["boards"]`, and therefore invisible to `AdminBoardBuild#set_boards`.
# The build page can't list it, publish/unpublish skip it, and destroying the
# build leaves it standing.
#
# The claim now commits with the boards, so no new orphans are produced. This
# task is for the ones already shipped.
#
#   bin/rails admin_board_builds:orphans                  # report only
#   bin/rails admin_board_builds:orphans UNPUBLISH=1      # take them off /pb/
#   bin/rails admin_board_builds:orphans APPLY=1          # destroy them
#
# Env: LIMIT (cap the number acted on), OLDER_THAN_DAYS (skip anything newer, so
# a build still running can't be mistaken for an orphan — defaults to 1).
namespace :admin_board_builds do
  desc "Report (or clean up) admin-builder boards that no AdminBoardBuild owns"
  task orphans: :environment do
    apply = ENV["APPLY"] == "1"
    unpublish = ENV["UNPUBLISH"] == "1"
    limit = ENV["LIMIT"].presence&.to_i
    older_than = Integer(ENV.fetch("OLDER_THAN_DAYS", 1))

    # Every board id any build points at: its root, plus every page recorded in
    # the art report. Read in one pass rather than per board.
    owned = Set.new
    AdminBoardBuild.find_each do |build|
      owned << build.board_id if build.board_id
      owned.merge(Array(build.art_report.presence&.dig("boards")&.values))
      owned.merge(Array(build.art_report.presence&.dig("linked_boards")&.values))
    end

    scope = AdminBoardBuild.builder_boards
                           .where.not(id: owned.to_a.compact)
                           .where(created_at: ..older_than.days.ago)
                           .order(:created_at)
    scope = scope.limit(limit) if limit

    orphans = scope.to_a

    if orphans.empty?
      puts "No orphaned admin-builder boards. #{owned.size} board(s) are owned by a build."
      next
    end

    puts "#{orphans.size} orphaned admin-builder board(s) — owned by no AdminBoardBuild:"
    orphans.each do |board|
      puts format(
        "  #%-8d %-40s %2d cols · %3d tiles · %-9s · /pb/%s · %s",
        board.id,
        board.name.to_s.truncate(40),
        board.number_of_columns.to_i,
        board.board_images.count,
        board.published? ? "published" : "draft",
        board.slug,
        board.created_at.to_date,
      )
    end

    if apply
      # Children first: a page's back tile is a predictive_board_id onto the
      # root, and destroying the root first leaves those dangling for as long as
      # the loop runs. Same ordering the controller's destroy uses.
      roots, pages = orphans.partition { |board| board.settings.to_h["builder_root"] }
      (pages + roots).each(&:destroy)
      puts "\nDestroyed #{orphans.size} board(s)."
    elsif unpublish
      count = orphans.count(&:published?)
      orphans.each { |board| board.update!(published: false) }
      puts "\nUnpublished #{count} board(s). Re-run with APPLY=1 to destroy them."
    else
      puts "\nReport only. UNPUBLISH=1 to take them off /pb/, APPLY=1 to destroy them."
    end
  end
end
