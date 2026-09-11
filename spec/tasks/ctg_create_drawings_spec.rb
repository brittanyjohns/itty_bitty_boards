require "rails_helper"
require "rake"

RSpec.describe "ctg:create_drawings" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ctg:create_drawings")
  end

  let(:task) { Rake::Task["ctg:create_drawings"] }

  it "creates the three CTG 2026 drawings with the right dates and source" do
    expect { task.execute }.to change(Event, :count).by(3)

    events = Event.where(lead_source: "ctg").order(:date)
    expect(events.map(&:date)).to eq(%w[2026-10-20 2026-10-21 2026-10-22])
    expect(events.map(&:time_zone).uniq).to eq(["America/Chicago"])
    expect(events.map(&:name)).to eq([
      "CTG 2026 Drawing — Tue Oct 20",
      "CTG 2026 Drawing — Wed Oct 21",
      "CTG 2026 Drawing — Thu Oct 22",
    ])
    expect(events.map(&:slug)).to eq(%w[
      ctg-2026-drawing-tue-oct-20
      ctg-2026-drawing-wed-oct-21
      ctg-2026-drawing-thu-oct-22
    ])
  end

  it "is idempotent — running it twice still leaves three events" do
    task.execute
    expect { task.execute }.not_to change(Event, :count)

    expect(Event.where(lead_source: "ctg").count).to eq(3)
  end

  it "leaves existing entries alone on a re-run" do
    task.execute
    event = Event.find_by(slug: "ctg-2026-drawing-wed-oct-21")
    create(:contest_entry, event: event, email: "entrant@example.com")

    task.execute

    expect(event.reload.contest_entries.count).to eq(1)
  end

  it "makes the created events resolvable by Event.drawing_for" do
    task.execute

    at = ActiveSupport::TimeZone["America/Chicago"].parse("2026-10-22 08:00")
    expect(Event.drawing_for(source: "ctg", at: at).slug).to eq("ctg-2026-drawing-thu-oct-22")
  end
end
