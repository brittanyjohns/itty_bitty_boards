# app/sidekiq/seed_board_builder_templates_job.rb
#
# Async half of the re-seed buttons on /admin/board_builder_templates. Both kinds
# of re-seed are far too slow to run in a request:
#
#   fringe — 11 .obf files x ~40 buttons through Board.from_obf, and every button
#            that doesn't match an existing Image creates one, each of which
#            queues a CategorizeImageJob from its after_commit.
#   vocab  — a whole OBZ import (~30 boards) plus five sync passes, one of which
#            is a destroy_all.
#
# Both are DESTRUCTIVE by design: they prune tiles and boards that vanished from
# the authored source, which is how a content revision fully applies. Scope is
# always admin-owned seed material — a user's built set is a deep copy and is
# never touched.
#
# The slug/basename is re-validated HERE as well as in the controller: a job can
# be replayed from the Sidekiq UI, so edge validation alone is not enough.
class SeedBoardBuilderTemplatesJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(kind, target = nil)
    case kind.to_s
    when "fringe" then seed_fringe(target)
    when "vocab"  then seed_vocab(target)
    else
      Rails.logger.error("[SeedBoardBuilderTemplatesJob] unknown kind #{kind.inspect}")
    end
  end

  private

  def seed_fringe(basename)
    if basename.blank?
      boards = Boards::FringeTemplates.seed_all!
      Rails.logger.info("[SeedBoardBuilderTemplatesJob] re-seeded #{boards.size} fringe templates")
      return
    end

    path = fringe_path(basename)
    unless path
      Rails.logger.error("[SeedBoardBuilderTemplatesJob] no fringe source named #{basename.inspect}")
      return
    end

    board = Boards::FringeTemplates.seed_obf!(path)
    Rails.logger.info("[SeedBoardBuilderTemplatesJob] re-seeded fringe template #{board&.name.inspect}")
  end

  # Sources are nested one directory per core set ("core-60/animals.obf"), so the
  # identifier is a RELATIVE path rather than a bare basename. It is matched
  # against the authored glob as an allowlist — never interpolated into a path,
  # which is what keeps a replayed job from reaching outside the seed dir.
  def fringe_path(relative_name)
    wanted = relative_name.to_s.delete_prefix("/")
    return nil unless wanted.end_with?(".obf")

    Boards::FringeTemplates.seed_files.find do |path|
      Pathname.new(path).relative_path_from(Boards::FringeTemplates::SEED_DIR).to_s == wanted
    end
  end

  def seed_vocab(slug)
    unless VocabSets.available_slugs.include?(slug.to_s)
      Rails.logger.error("[SeedBoardBuilderTemplatesJob] no authored source for slug #{slug.inspect}")
      return
    end

    root = VocabSets.seed_slug!(slug.to_s)
    Rails.logger.info("[SeedBoardBuilderTemplatesJob] re-seeded #{slug} (root board #{root&.id})")
    # The vocab rake task re-seeds fringe templates too, because a set's pages and
    # the standalone templates are authored together and drift apart otherwise.
    Boards::FringeTemplates.seed_all!
  end
end
