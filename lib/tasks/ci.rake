# frozen_string_literal: true

namespace :ci do
  desc "Regenerate spec/ci_timings.json from spec/examples.txt (run a FULL suite first)"
  task :timings do
    require "json"

    examples = Rails.root.join("spec/examples.txt")
    abort("#{examples} not found — run a full `bundle exec rspec` first") unless examples.exist?

    totals = Hash.new(0.0)
    counts = Hash.new(0)

    examples.each_line do |line|
      # example_id | status | run_time
      # ./spec/models/board_spec.rb[1:2:3] | passed | 0.041 seconds |
      id, _status, run_time = line.split("|", 4)
      next if id.nil? || run_time.nil?

      file = id.strip.sub(/\[.*\z/, "").delete_prefix("./")
      next unless file.end_with?("_spec.rb")

      seconds = run_time[/[\d.]+/]
      next if seconds.nil?

      totals[file] += seconds.to_f
      counts[file] += 1
    end

    abort("no timings parsed out of #{examples}") if totals.empty?

    on_disk = Dir.glob(Rails.root.join("spec/**/*_spec.rb"))
                 .map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }

    # A partial run leaves stale entries for files it didn't touch, and the
    # resulting split would be balanced against fiction. Warn loudly rather
    # than write a file that looks authoritative.
    missing = on_disk - totals.keys
    if missing.any?
      warn("WARNING: #{missing.size} of #{on_disk.size} spec files have no timing.")
      warn("         spec/examples.txt looks like a PARTIAL run. Re-run the full suite:")
      warn("           bundle exec rspec")
      warn("         Writing anyway — bin/ci-shard will use the median for the rest.")
    end

    rounded = totals.sort.to_h { |file, seconds| [file, seconds.round(3)] }
    out = Rails.root.join("spec/ci_timings.json")
    out.write("#{JSON.pretty_generate(rounded)}\n")

    slowest = rounded.max_by(10) { |_f, s| s }
    puts "Wrote #{out} — #{rounded.size} files, #{totals.values.sum.round(1)}s total."
    puts "Slowest:"
    slowest.each { |f, s| puts format("  %8.1fs  %s", s, f) }
  end
end
