namespace :tile_audio do
  # Backfill for tiles left with no `audio_url` by a SaveAudioJob that was
  # pushed from inside the transaction that created the tile. Sidekiq dequeued
  # before the commit, `image.board_images.find_by(id:)` returned nil, and the
  # job logged "BoardImage with ID ... not found" and moved on — so the audio
  # FILE was written to the Image, but the tile's own `audio_url`/`voice`
  # columns were never filled in.
  #
  # These tiles do not heal themselves. `Board#api_view_with_images` only
  # re-enqueues when `board_image.voice != voice_to_play`, and `set_defaults`
  # stamps the tile with the board's voice at creation — so the comparison is
  # equal, the else branch hands the serializer a nil `audio_url`, and the tile
  # ships mute on every subsequent load.
  #
  # Two windows produced them:
  #   * Everything created inside a transaction before #303 moved
  #     `create_voice_audio_after_create` to `after_create_commit`.
  #   * `Board#set_voice`, which runs from a `before_save` callback and pushed
  #     the job inline, until it was routed through
  #     `BoardImage#enqueue_voice_audio_job`.
  #
  # Repair is cheap for most rows: the tile's Image is asked first whether a
  # file already exists for that voice, and it usually DOES — the original job
  # got that far before failing to find the tile. Only a tile with no matching
  # file falls through to a fresh SaveAudioJob.
  #
  #   bin/rails tile_audio:missing_report                  # dry run, whole database
  #   bin/rails tile_audio:missing_report ADMIN_BUILT=1
  #   bin/rails tile_audio:backfill APPLY=1 BOARD_ID=5827
  #   bin/rails tile_audio:backfill APPLY=1 LIMIT=500
  #
  # Env: BOARD_ID, USER_ID, ADMIN_BUILT=1 (scope) · LIMIT (cap rows touched)
  #      SAMPLE (rows to print, default 25) · ENQUEUE=0 (repair only from files
  #      that already exist; never queue Polly work)

  # A tile playing a parent's recording is not missing anything — `audio_url`
  # holds the recording, and a blank one there means the upload failed, which is
  # a different problem with a different fix. Never let this task push such a
  # tile back onto a synthesized voice.
  missing_audio_scope = lambda do
    # Table-qualified: `boards` carries a `data` column too, so an unqualified
    # reference is ambiguous the moment anything joins the two.
    scope = BoardImage.where(audio_url: [nil, ""])
                      .where("board_images.data->>'using_custom_audio' IS DISTINCT FROM 'true'")

    if ENV["BOARD_ID"].present?
      scope = scope.where(board_id: ENV["BOARD_ID"].to_i)
    elsif ENV["USER_ID"].present?
      scope = scope.where(board_id: Board.where(user_id: ENV["USER_ID"].to_i).select(:id))
    elsif ENV["ADMIN_BUILT"] == "1"
      admin_built = Board.where("settings->>? = 'true'", AdminBoardBuild::BUILDER_SETTING)
      scope = scope.where(board_id: admin_built.select(:id))
    end

    scope
  end

  desc "Report tiles whose audio_url was never written (dry run)"
  task missing_report: :environment do
    scope = missing_audio_scope.call
    total = scope.count
    sample_size = (ENV["SAMPLE"].presence || 25).to_i

    puts "Tiles with no audio_url: #{total}"

    if total.zero?
      puts "Nothing to backfill."
    else
      # `reorder(nil)`: BoardImage carries a default position order, which
      # Postgres rejects alongside GROUP BY.
      by_board = scope.reorder(nil).group(:board_id).count.sort_by { |_, count| -count }
      puts "Across #{by_board.size} boards. Worst offenders:"
      by_board.first(sample_size).each do |board_id, count|
        board = Board.find_by(id: board_id)
        name = (board&.name || "(deleted)").to_s.truncate(40)
        admin_built = board&.settings.is_a?(Hash) && board.settings[AdminBoardBuild::BUILDER_SETTING] == true
        puts format("  board %-8s %-40s %4d tiles%s", board_id, name, count, admin_built ? "  [admin-built]" : "")
      end

      # The split that decides urgency. A tile whose `voice` differs from its
      # board's still hits the re-enqueue branch in
      # `Board#api_view_with_images` and repairs itself on the next board load.
      # A tile whose voice MATCHES takes the else branch, is serialized with a
      # nil `audio_url`, and stays mute forever — those are the ones a backfill
      # is actually for.
      stuck = scope.joins(:board).where("board_images.voice = boards.voice").count
      puts "Of those, #{stuck} will never self-heal (tile voice matches the board's) — " \
           "#{total - stuck} repair themselves on the next board load."

      # How many can be repaired straight from a file that already exists tells
      # you what the backfill actually costs: those rows are a column write, the
      # rest are Polly calls.
      sampled = scope.includes(:image).limit(sample_size).to_a
      resolvable = sampled.count do |board_image|
        board_image.audio_url_for_voice(board_image.voice, board_image.language).present?
      end
      puts "Of the #{sampled.size} sampled, #{resolvable} already have an audio file to point at."
      puts "Re-run with APPLY=1 on tile_audio:backfill to repair."
    end
  end

  desc "Repair tiles whose audio_url was never written (APPLY=1 to write)"
  task backfill: :environment do
    apply = ENV["APPLY"] == "1"
    enqueue = ENV["ENQUEUE"] != "0"
    limit = ENV["LIMIT"].presence&.to_i

    repaired = 0
    enqueued = 0
    skipped = 0

    # `find_each` ignores a scope's limit, so a capped run has to iterate the
    # limited relation directly. Uncapped runs keep the batching.
    scope = missing_audio_scope.call.includes(:image)
    rows = limit ? scope.limit(limit).to_a : scope

    iterate = lambda do |&block|
      rows.respond_to?(:find_each) && limit.nil? ? rows.find_each(&block) : rows.each(&block)
    end

    iterate.call do |board_image|
      existing = board_image.audio_url_for_voice(board_image.voice, board_image.language)

      if existing.present?
        repaired += 1
        board_image.update_columns(audio_url: existing) if apply
      elsif enqueue
        enqueued += 1
        # Goes through the same guarded enqueue the app uses, so the task can
        # never reintroduce the ordering bug it exists to clean up.
        board_image.enqueue_voice_audio_job if apply
      else
        skipped += 1
      end
    end

    puts "#{apply ? 'Repaired' : 'Would repair'} #{repaired} tiles from audio files that already exist."
    puts "#{apply ? 'Queued' : 'Would queue'} #{enqueued} SaveAudioJob pushes for tiles with no file yet."
    puts "Skipped #{skipped} tiles with no file (ENQUEUE=0)." if skipped.positive?
    puts "Dry run — nothing written. Re-run with APPLY=1." unless apply
  end
end
