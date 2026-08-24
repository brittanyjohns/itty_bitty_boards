namespace :library_images do
  # Bulk dedupe of the SEEDED LIBRARY — the images every new user's boards are
  # built from. Nothing a user uploaded is ever in scope.
  #
  # Two steps, always, and they are separate commands on purpose:
  #
  #   1. `scan` runs Images::DuplicateScanner (a pure read) and stores the
  #      result as a `planned` ImageMergeBatch. It writes no image data.
  #   2. `apply[ID]` enqueues ImageMergeBatchJob, which fans out one
  #      ImageMergeJob per group onto the low-priority `maintenance` queue.
  #
  # There is no flag that does both. Merging destroys Image rows and `images`
  # has no soft-delete, so the review step is the safety.
  #
  #   bin/rails library_images:scan
  #   bin/rails library_images:scan LABEL=food LIMIT=25
  #   bin/rails 'library_images:show[12]'
  #   bin/rails 'library_images:apply[12]'
  #   bin/rails 'library_images:pause[12]'
  #   bin/rails library_images:default_health
  #
  # Env: LABEL (one label only) · LIMIT (cap groups) · SAMPLE (rows to print,
  #      default 15)

  desc "Scan the seeded library for duplicate labels and store a reviewable plan (writes no image data)"
  task scan: :environment do
    limit = ENV["LIMIT"].presence&.to_i
    label = ENV["LABEL"].presence

    puts "Scanning library images#{label ? " for label '#{label}'" : ""}..."
    result = Images::DuplicateScanner.call(label: label, limit: limit)
    report = result["report"]

    if result["groups"].empty?
      puts "No duplicate groups found. Nothing to do."
      next
    end

    batch = ImageMergeBatch.create!(
      status: "planned",
      plan: { "groups" => result["groups"] },
      report: report,
      filters: { "label" => label, "limit" => limit }.compact,
    )

    puts ""
    puts "Batch ##{batch.id} (planned — nothing has been changed)"
    print_report(report)
    print_sample(result["groups"])
    puts ""
    puts "Review it with:  bin/rails 'library_images:show[#{batch.id}]'"
    puts "Apply it with:   bin/rails 'library_images:apply[#{batch.id}]'"
  end

  desc "Print a stored batch's plan and progress"
  task :show, [:batch_id] => :environment do |_t, args|
    batch = find_batch!(args[:batch_id])
    next unless batch

    puts "Batch ##{batch.id} — #{batch.status}"
    puts "Filters: #{batch.filters.inspect}" if batch.filters.present?
    puts "Error: #{batch.error_message}" if batch.error_message.present?
    print_report(batch.report)
    puts ""
    puts "Progress: #{batch.summary.inspect}"
    print_sample(batch.groups)

    skipped = batch.image_merges.where(status: %w[skipped failed]).limit(20)
    if skipped.any?
      puts ""
      puts "Skipped / failed groups:"
      skipped.each { |m| puts "  group #{m.group_index} (#{m.label}) — #{m.status}: #{m.skip_reason}" }
    end
  end

  desc "Enqueue the merge fan-out for a stored batch"
  task :apply, [:batch_id] => :environment do |_t, args|
    batch = find_batch!(args[:batch_id])
    next unless batch

    unless batch.planned? || batch.paused?
      puts "Batch ##{batch.id} is '#{batch.status}' — only a planned or paused batch can be applied."
      next
    end

    puts "Enqueuing #{batch.groups.size} merge jobs for batch ##{batch.id} on the `maintenance` queue."
    puts "Pause at any time with: bin/rails 'library_images:pause[#{batch.id}]'"
    ImageMergeBatchJob.perform_async(batch.id)
  end

  desc "Stop an in-flight batch (queued jobs become no-ops)"
  task :pause, [:batch_id] => :environment do |_t, args|
    batch = find_batch!(args[:batch_id])
    next unless batch

    batch.mark_paused!
    puts "Batch ##{batch.id} paused. Queued jobs will return without merging."
    puts "Resume with: bin/rails 'library_images:apply[#{batch.id}]'"
  end

  desc "Report on library images with no usable default picture"
  task default_health: :environment do
    scope = Images::DuplicateScanner.candidate_scope
    total = scope.count

    counts = Doc.where(documentable_type: "Image", documentable_id: scope.select(:id))
                .group(:documentable_id)
                .pluck(Arel.sql("documentable_id, COUNT(*), COUNT(*) FILTER (WHERE current)"))

    seen = counts.to_h { |id, all, cur| [id, [all, cur]] }
    no_docs = total - seen.size
    none_current = seen.count { |_id, (_all, cur)| cur.zero? }
    multi_current = seen.count { |_id, (_all, cur)| cur > 1 }
    blank_src = scope.where(src_url: [nil, ""]).count

    puts "Library images:            #{total}"
    puts "  no docs at all:          #{no_docs}"
    puts "  docs but none current:   #{none_current}"
    puts "  MULTIPLE current docs:   #{multi_current}   <- ambiguous default"
    puts "  blank src_url:           #{blank_src}"
  end

  def find_batch!(id)
    batch = ImageMergeBatch.find_by(id: id)
    puts "No ImageMergeBatch with id #{id.inspect}." unless batch
    batch
  end

  def print_report(report)
    report = report.with_indifferent_access
    puts "  duplicate groups:     #{report[:groups]}"
    puts "  redundant rows:       #{report[:redundant_rows]}"
    puts "  mixed art (rescues a blank row):  #{report[:mixed_art_groups]}"
    puts "  all rows have art:                #{report[:all_have_art_groups]}"
    puts "  no art anywhere (needs generation, not merging): #{report[:all_blank_groups]}"
  end

  def print_sample(groups)
    sample_size = (ENV["SAMPLE"].presence || 15).to_i
    return if groups.empty?

    puts ""
    puts "Largest groups:"
    groups.first(sample_size).each do |g|
      label, lang, pos = g["key"]
      puts format("  %-28s %-4s %-10s keep %-8s drop %s",
                  label, lang, pos, g["survivor_id"], g["loser_ids"].size)
    end
  end
end
