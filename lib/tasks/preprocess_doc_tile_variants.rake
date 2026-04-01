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

    if batch_size <= 0
      puts "BATCH_SIZE must be greater than 0"
      exit 1
    end

    base_scope = Doc
      .joins("INNER JOIN images ON images.id = docs.documentable_id")
      .joins("INNER JOIN board_images ON board_images.image_id = images.id")
      .where(documentable_type: "Image")
      .with_attached_image
      .where("docs.data ->> 'tile_variant_processed' IS DISTINCT FROM 'true'")

    left_to_process = base_scope.count

    puts "Base scope: #{base_scope.count} docs"

    base_scope = base_scope.where("docs.id >= ?", start_id) if start_id.present?

    latest_doc_scope = base_scope
      .select("DISTINCT ON (docs.documentable_id) docs.id, docs.documentable_id, docs.created_at")
      .order("docs.documentable_id, docs.created_at DESC")

    latest_doc_ids = latest_doc_scope.pluck(:id).uniq
    latest_doc_ids = latest_doc_ids.first(limit) if limit.present?

    already_enqueued_doc_ids = Set.new

    if skip_already_enqueued
      job_classes = ["PreprocessDocTileVariantJob", "PreprocessDocTileVariantsJob"]

      Sidekiq::ScheduledSet.new.each do |job|
        next unless job_classes.include?(job.klass)
        extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
      end

      Sidekiq::RetrySet.new.each do |job|
        next unless job_classes.include?(job.klass)
        extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
      end

      Sidekiq::Queue.new(queue_name).each do |job|
        next unless job_classes.include?(job.klass)
        extract_doc_ids_from_job(job).each { |id| already_enqueued_doc_ids << id }
      end
    end

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
    end

    puts "Done."
    puts "Docs seen: #{docs_seen}"
    puts "Docs skipped as already processed: #{docs_skipped_processed}"
    puts "Docs skipped as already enqueued: #{docs_skipped_enqueued}"
    puts "Docs enqueued: #{docs_enqueued}"
    puts "Jobs enqueued: #{jobs_enqueued}"

    puts "\nleft_to_process: #{left_to_process}"
  end

  desc "Delete scheduled and retry tile variant jobs"
  task clear_tile_variant_jobs: :environment do
    require "sidekiq/api"

    job_classes = ["PreprocessDocTileVariantJob", "PreprocessDocTileVariantsJob"]

    scheduled_deleted = 0
    retry_deleted = 0

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

    puts "Deleted #{scheduled_deleted} scheduled jobs"
    puts "Deleted #{retry_deleted} retry jobs"
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
