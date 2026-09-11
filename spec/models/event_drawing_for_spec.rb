require "rails_helper"

# Event.drawing_for is the single place that answers "which drawing is running
# right now?". The app time zone is UTC, so it must convert into the event's
# own time_zone before taking the calendar day. #910
RSpec.describe Event, ".drawing_for" do
  let!(:tuesday) do
    create(:event, name: "Tue", slug: "ctg-tue", date: "2026-10-20",
                   lead_source: "ctg", time_zone: "America/Chicago")
  end
  let!(:wednesday) do
    create(:event, name: "Wed", slug: "ctg-wed", date: "2026-10-21",
                   lead_source: "ctg", time_zone: "America/Chicago")
  end

  def central(time_string)
    ActiveSupport::TimeZone["America/Chicago"].parse(time_string)
  end

  it "finds the event whose local date matches" do
    expect(described_class.drawing_for(source: "ctg", at: central("2026-10-21 12:00"))).to eq(wednesday)
  end

  it "uses the event's time zone, not UTC, for the calendar day" do
    late = central("2026-10-20 23:30")
    expect(late.utc.to_date.iso8601).to eq("2026-10-21")

    expect(described_class.drawing_for(source: "ctg", at: late)).to eq(tuesday)
  end

  it "still resolves the Tuesday event just after midnight UTC on the 21st" do
    expect(described_class.drawing_for(source: "ctg", at: Time.utc(2026, 10, 21, 0, 30))).to eq(tuesday)
  end

  it "returns nil when no event of that source runs today" do
    expect(described_class.drawing_for(source: "ctg", at: central("2026-10-23 09:00"))).to be_nil
  end

  it "returns nil for another source" do
    expect(described_class.drawing_for(source: "free_download", at: central("2026-10-21 12:00"))).to be_nil
  end

  it "returns nil for a blank source" do
    expect(described_class.drawing_for(source: nil, at: central("2026-10-21 12:00"))).to be_nil
    expect(described_class.drawing_for(source: "", at: central("2026-10-21 12:00"))).to be_nil
  end

  it "ignores events with no date" do
    create(:event, name: "Undated", slug: "ctg-undated", date: nil, lead_source: "ctg")

    expect(described_class.drawing_for(source: "ctg", at: central("2026-10-23 09:00"))).to be_nil
  end

  it "honours a non-Central event time zone" do
    create(:event, name: "Pacific", slug: "pac-day", date: "2026-10-20",
                   lead_source: "pacific", time_zone: "America/Los_Angeles")

    # 01:00 UTC on the 21st is still 18:00 on the 20th in Los Angeles.
    expect(described_class.drawing_for(source: "pacific", at: Time.utc(2026, 10, 21, 1, 0)).slug)
      .to eq("pac-day")
  end
end
