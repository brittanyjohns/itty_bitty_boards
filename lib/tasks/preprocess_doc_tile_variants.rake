namespace :docs do
  desc "Backfill tile variants for docs used on boards"
  task preprocess_tile_variants: :environment do
    require "sidekiq/api"
    require "set"

    batch_size = ENV.fetch("BATCH_SIZE", 10).to_i
    delay_seconds = ENV.fetch("DELAY_SECONDS", 10).to_i
    limit = ENV["LIMIT"]&.to_i
    start_id = ENV["START_ID"]&.to_i
    dry_run = ENV.fetch("DRY_RUN", "false") == "true"
    skip_processed = ENV.fetch("SKIP_PROCESSED", "true") == "true"
    skip_already_enqueued = ENV.fetch("SKIP_ALREADY_ENQUEUED", "true") == "true"
    queue_name = ENV.fetch("QUEUE", "default")
    board_id = ENV["BOARD_ID"]&.to_i
    user_id = ENV["USER_ID"]&.to_i

    if batch_size <= 0
      puts "BATCH_SIZE must be greater than 0"
      exit 1
    end

    base_scope = Doc
      .joins("INNER JOIN images ON images.id = docs.documentable_id")
      .joins("INNER JOIN board_images ON board_images.image_id = images.id")
      .joins("INNER JOIN boards ON boards.id = board_images.board_id")
      .where("boards.published = true OR boards.predefined = true")
      .where(documentable_type: "Image")
      .with_attached_image
    if user_id.present?
      # unscope published/predefined condition if we're scoping by board or user, since that implies we want to include all boards for that board/user, not just published/predefined ones
      base_scope = Doc
        .joins("INNER JOIN images ON images.id = docs.documentable_id")
        .joins("INNER JOIN board_images ON board_images.image_id = images.id")
        .joins("INNER JOIN boards ON boards.id = board_images.board_id")
        .where(documentable_type: "Image")
        .with_attached_image
    end

    # base_scope = base_scope.where("boards.id = ?", board_id) if board_id.present?
    base_scope = base_scope.where("boards.user_id = ?", user_id) if user_id.present?
    if board_id.present?
      board = Board.find_by(id: board_id)
      unless board
        puts "Board with id=#{board_id} not found"
        exit(1)
      end
      puts "Filtering to boards with id=#{board_id} (#{board.name})"
      base_scope = board.display_docs
    end

    puts "Base scope: #{base_scope.count} docs"

    base_scope = base_scope.where("docs.id >= ?", start_id) if start_id.present?

    # latest_doc_scope = base_scope
    #   .select("DISTINCT ON (docs.documentable_id) docs.id, docs.documentable_id, docs.created_at")
    #   .order("docs.documentable_id, docs.created_at DESC")
    latest_doc_scope = base_scope

    latest_doc_ids = latest_doc_scope.pluck(:id).uniq
    puts "About to process #{latest_doc_ids.size} docs for tile variant backfill\nDo you want to continue? (y/n)"
    answer = STDIN.gets.chomp.downcase
    unless answer.in?(%w[y yes])
      puts "Aborting. - you entered #{answer.inspect}"
      exit(0)
    end
    total_candidate_docs = latest_doc_ids.size
    left_to_process = total_candidate_docs
    latest_doc_ids = latest_doc_ids.first(limit) if limit.present?

    already_enqueued_doc_ids = Set.new

    # if skip_already_enqueued
    #   job_classes = ["PreprocessDocTileVariantJob", "PreprocessDocTileVariantsJob"]

    #   Sidekiq::ScheduledSet.new.each do |job|
    #     next unless job_classes.include?(job.klass)
    #     extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
    #   end

    #   Sidekiq::RetrySet.new.each do |job|
    #     next unless job_classes.include?(job.klass)
    #     extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
    #   end

    #   Sidekiq::Queue.new(queue_name).each do |job|
    #     next unless job_classes.include?(job.klass)
    #     extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
    #   end
    # end

    puts "Starting tile variant backfill enqueue..."
    puts "Candidate docs: #{latest_doc_ids.size}"
    puts "Already enqueued docs: #{already_enqueued_doc_ids.size}"
    puts "BATCH_SIZE=#{batch_size}"
    puts "DELAY_SECONDS=#{delay_seconds}"
    puts "LIMIT=#{limit || "none"}"
    puts "START_ID=#{start_id || "none"}"
    puts "DRY_RUN=#{dry_run}"
    puts "SKIP_PROCESSED=#{skip_processed}"
    puts "SKIP_ALREADY_ENQUEUED=#{skip_already_enqueued}"

    docs_seen = 0
    docs_enqueued = 0
    docs_skipped_processed = 0
    docs_skipped_enqueued = 0
    jobs_enqueued = 0
    puts "Processing doc IDs in batches of #{batch_size} with a delay of #{delay_seconds}s between batches..."
    puts "Total batches to process: #{(latest_doc_ids.size / batch_size.to_f).ceil}"

    latest_doc_ids.each_slice(batch_size).with_index do |doc_ids_batch, batch_index|
      docs = Doc.where(id: doc_ids_batch).with_attached_image.to_a
      docs_seen += docs.size

      docs_to_enqueue = docs

      if skip_processed
        before = docs_to_enqueue.size
        docs_to_enqueue = docs_to_enqueue.reject(&:tile_variant_done?)
        docs_skipped_processed += (before - docs_to_enqueue.size)
      end

      if skip_already_enqueued
        before = docs_to_enqueue.size
        docs_to_enqueue = docs_to_enqueue.reject { |doc| already_enqueued_doc_ids.include?(doc.id) }
        docs_skipped_enqueued += (before - docs_to_enqueue.size)
      end

      next if docs_to_enqueue.empty?

      doc_ids = docs_to_enqueue.map(&:id)
      run_in_seconds = batch_index * delay_seconds

      if dry_run
        puts "\n[DRY RUN] Would enqueue PreprocessDocTileVariantsJob in #{run_in_seconds}s for doc_ids=#{doc_ids.inspect}"
      else
        PreprocessDocTileVariantsJob.perform_in(run_in_seconds, doc_ids)
        puts "\nEnqueued PreprocessDocTileVariantsJob in #{run_in_seconds}s for #{doc_ids.size} docs (ids #{doc_ids.first}..#{doc_ids.last})"
      end

      docs_enqueued += doc_ids.size
      jobs_enqueued += 1
      sleep(delay_seconds) unless dry_run
    end

    puts "Done."
    puts "Docs seen: #{docs_seen}"
    puts "Docs skipped as already processed: #{docs_skipped_processed}"
    puts "Docs skipped as already enqueued: #{docs_skipped_enqueued}"
    puts "Docs enqueued: #{docs_enqueued}"
    puts "Jobs enqueued: #{jobs_enqueued}"
  end

  desc "Convert PNG images to WebP for docs used on boards. Example: `BOARD_IDS=6536,6537 bundle exec rake docs:convert_png_to_webp`"
  task convert_png_to_webp: :environment do
    limit = ENV["LIMIT"]&.to_i || 10
    base_scope = Doc
      .joins("INNER JOIN images ON images.id = docs.documentable_id")
      .joins("INNER JOIN board_images ON board_images.image_id = images.id")
      .joins("INNER JOIN boards ON boards.id = board_images.board_id")
      .where(documentable_type: "Image")
      .with_attached_image
      .where("docs.data ->> 'converted_to_webp' IS DISTINCT FROM 'true'")
    base_scope = base_scope.where("boards.id = ?", ENV["BOARD_ID"].to_i) if ENV["BOARD_ID"].present?
    base_scope = base_scope.where("boards.user_id = ?", ENV["USER_ID"].to_i) if ENV["USER_ID"].present?

    scope = base_scope.joins(:image_attachment, :image_blob)
      .where(active_storage_blobs: { content_type: "image/png" })

    puts "Found #{scope.count} PNG images"
    count = 0
    scope.find_each do |doc|
      ConvertDocToWebpJob.perform_async(doc.id)
      count += 1
      break if count >= limit
    end
    puts "Enqueued conversion jobs for #{count} PNG images"
  end

  desc "Delete scheduled and retry tile variant jobs"
  task clear_tile_variant_jobs: :environment do
    require "sidekiq/api"

    job_classes = ["PreprocessDocTileVariantJob", "PreprocessDocTileVariantsJob"]

    scheduled_deleted = 0
    retry_deleted = 0
    enqueued_deleted = 0

    Sidekiq::ScheduledSet.new.each do |job|
      next unless job_classes.include?(job.klass)
      job.delete
      scheduled_deleted += 1
    end

    Sidekiq::RetrySet.new.each do |job|
      next unless job_classes.include?(job.klass)
      job.delete
      retry_deleted += 1
    end

    Sidekiq::Queue.new("ai_images").each do |job|
      next unless job_classes.include?(job.klass)
      job.delete
      enqueued_deleted += 1
    end

    puts "Deleted #{scheduled_deleted} scheduled jobs"
    puts "Deleted #{retry_deleted} retry jobs"
    puts "Deleted #{enqueued_deleted} enqueued jobs"
  end

  desc "Inspect scheduled and retry tile variant jobs"
  task inspect_tile_variant_jobs: :environment do
    require "sidekiq/api"

    job_classes = ["PreprocessDocTileVariantJob", "PreprocessDocTileVariantsJob"]

    puts "=== Scheduled Jobs ==="
    scheduled_count = 0
    Sidekiq::ScheduledSet.new.each do |job|
      next unless job_classes.include?(job.klass)
      scheduled_count += 1
      puts "#{job.klass} | at=#{Time.at(job.at)} | args=#{job.args.inspect}"
    end
    puts "Total scheduled: #{scheduled_count}"

    puts "\n=== Retry Jobs ==="
    retry_count = 0
    Sidekiq::RetrySet.new.each do |job|
      next unless job_classes.include?(job.klass)
      retry_count += 1
      puts "#{job.klass} | error=#{job.error_class} | message=#{job.error_message} | args=#{job.args.inspect}"
    end
    puts "Total retries: #{retry_count}"

    puts "\n=== Queue Jobs ==="
    queue_count = 0
    Sidekiq::Queue.new("default").each do |job|
      next unless job_classes.include?(job.klass)
      queue_count += 1
      puts "#{job.klass} | args=#{job.args.inspect}"
    end
    puts "Total queued: #{queue_count}"
  end

  desc "Reprocess tile variants with new transformations"
  task reprocess_tile_variants: :environment do
    batch_size = ENV.fetch("BATCH_SIZE", 50).to_i
    delay_seconds = ENV.fetch("DELAY_SECONDS", 2).to_i

    docs = Doc.with_attached_image

    puts "Total docs: #{docs.count}"

    docs.find_in_batches(batch_size: batch_size).with_index do |batch, index|
      puts "Processing batch #{index + 1}..."

      batch.each_with_index do |doc, i|
        PreprocessDocTileVariantJob.perform_in(i * delay_seconds, doc.id)
      end

      sleep(delay_seconds)
    end

    puts "Done enqueuing jobs"
  end

  def extract_doc_ids_from_job(job)
    args = job.args

    case job.klass
    when "PreprocessDocTileVariantJob"
      [args.first].compact.map(&:to_i)
    when "PreprocessDocTileVariantsJob"
      Array(args.first).compact.map(&:to_i)
    else
      []
    end
  rescue
    []
  end
end
