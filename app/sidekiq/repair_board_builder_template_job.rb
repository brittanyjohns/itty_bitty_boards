# app/sidekiq/repair_board_builder_template_job.rb
#
# Layout repair across a whole robust vocab set (~30 boards) — the Repair button
# on /admin/board_builder_templates for a Core 60/84 root. A single fringe
# template is repaired inline instead: it is one small board, and a backgrounded
# repair would leave the health panel still showing the defect it just fixed.
#
# unstack!, never repack!. An authored grid holds exactly as many cells as tiles,
# so a displaced tile belongs in the gap its twin left; repack! shelf-packs onto
# a NEW ROW, which silently defeats settings["disable_scroll"] — the exact damage
# this repairs.
class RepairBoardBuilderTemplateJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(board_id)
    root = Board.find_by(id: board_id)
    return Rails.logger.error("[RepairBoardBuilderTemplateJob] board #{board_id} not found") unless root

    slug = Boards::RobustSets.slug_for(root)
    boards = slug.present? ? Boards::RobustSets.set_boards(slug) : [root]

    totals = boards.reduce([0, 0]) do |(removed, moved), board|
      [removed + Boards::TileDeduper.collapse_duplicates!(board),
       moved + Boards::LayoutRepacker.unstack!(board)]
    end

    Rails.logger.info(
      "[RepairBoardBuilderTemplateJob] #{slug || root.id}: removed #{totals[0]} duplicate tiles, " \
      "moved #{totals[1]} displaced tiles across #{boards.size} boards",
    )
  end
end
