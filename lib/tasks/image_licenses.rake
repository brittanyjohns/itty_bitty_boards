# Read-only audit of what the image library is actually licensed under.
#
# The figures in the search-endpoints spec were measured 2026-07-22 and WILL
# drift as the library grows. Re-run this against production to refresh them
# before making a licensing decision.
#
#   bundle exec rake images:license_audit
namespace :images do
  desc "Report the license breakdown of the image library (read-only)"
  task license_audit: :environment do
    docs = Doc.includes(:image_attachment).where(deleted_at: nil)
    total = docs.count

    by_source = Hash.new(0)
    by_type   = Hash.new(0)
    safe = attribution = share_alike = 0

    docs.find_each do |doc|
      result = Images::CommercialLicense.for(doc)

      by_source[doc.source_type || "(none)"] += 1
      by_type[result.type || "(no license)"] += 1

      safe        += 1 if result.commercial_safe?
      attribution += 1 if result.attribution_required?
      share_alike += 1 if result.share_alike?
    end

    percent = lambda do |part, whole|
      next 0.0 if whole.zero?

      (part.to_f / whole) * 100
    end

    puts "\nImage library license audit — #{total} docs\n\n"

    puts "By source_type:"
    by_source.sort_by { |_, count| -count }.each { |name, count| puts format("  %-16s %6d", name, count) }

    puts "\nBy license type:"
    by_type.sort_by { |_, count| -count }.each { |name, count| puts format("  %-16s %6d", name, count) }

    puts "\nTotals:"
    puts format("  %-24s %6d  (%.1f%%)", "commercial-safe", safe, percent.call(safe, total))
    puts format("  %-24s %6d", "attribution-required", attribution)
    puts format("  %-24s %6d", "share-alike", share_alike)
    puts "\nNote: share-alike images are NOT counted as commercial-safe unless"
    puts "the caller passes include_share_alike. See the search-endpoints spec.\n\n"
  end
end
