namespace :ctg do
  # Creates the three Closing the Gap 2026 booth drawings (Oct 20-22,
  # Bloomington MN, Central time). Idempotent: keyed on slug, so re-running it
  # refreshes the attributes rather than creating duplicates.
  #
  # A rake task rather than a seed or migration because it is a production data
  # write for one conference. **Running it on production is Brittany's call** —
  # it waits for her explicit go-ahead after deploy. #910
  desc "Create (idempotently) the three CTG 2026 daily drawings"
  task create_drawings: :environment do
    drawings = [
      { slug: "ctg-2026-drawing-tue-oct-20", name: "CTG 2026 Drawing — Tue Oct 20", date: "2026-10-20" },
      { slug: "ctg-2026-drawing-wed-oct-21", name: "CTG 2026 Drawing — Wed Oct 21", date: "2026-10-21" },
      { slug: "ctg-2026-drawing-thu-oct-22", name: "CTG 2026 Drawing — Thu Oct 22", date: "2026-10-22" },
    ]

    drawings.each do |attrs|
      event = Event.find_or_initialize_by(slug: attrs[:slug])
      created = event.new_record?
      event.assign_attributes(attrs.merge(lead_source: "ctg", time_zone: "America/Chicago"))
      event.save!

      puts "#{created ? "created" : "updated"} #{event.slug} (#{event.date}, #{event.time_zone})"
    end

    puts "Done. #{Event.where(lead_source: "ctg").count} event(s) with lead_source \"ctg\"."
  end
end
