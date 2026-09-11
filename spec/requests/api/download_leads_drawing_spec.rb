require "rails_helper"

# POST /api/download_leads enters the lead into that day's booth drawing when
# one is configured for its `source`. #910
#
# The app time zone is UTC, so every assertion here goes through a Central-time
# wall clock on purpose — the 23:30 CT case is the whole point of the feature.
RSpec.describe "API download_leads drawing entry", type: :request do
  before { MailchimpUpsertLeadJob.jobs.clear }

  let!(:tuesday) do
    FactoryBot.create(:event, name: "CTG 2026 Drawing — Tue Oct 20", slug: "ctg-2026-drawing-tue-oct-20",
                              date: "2026-10-20", lead_source: "ctg", time_zone: "America/Chicago")
  end
  let!(:wednesday) do
    FactoryBot.create(:event, name: "CTG 2026 Drawing — Wed Oct 21", slug: "ctg-2026-drawing-wed-oct-21",
                              date: "2026-10-21", lead_source: "ctg", time_zone: "America/Chicago")
  end

  def ctg_params(email:, **extra)
    {
      download_lead: {
        email: email,
        source: "ctg",
        data: { utm_campaign: "ctg-2026" },
      }.merge(extra),
    }
  end

  def central(time_string)
    ActiveSupport::TimeZone["America/Chicago"].parse(time_string)
  end

  it "enters a ctg lead into that day's drawing and says so in the response" do
    travel_to central("2026-10-21 12:00") do
      expect {
        post "/api/download_leads", params: ctg_params(email: "Booth@Example.com")
      }.to change(ContestEntry, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["drawing"]).to eq(
        "entered" => true,
        "event_name" => "CTG 2026 Drawing — Wed Oct 21",
      )
    end

    entry = ContestEntry.last
    expect(entry.event).to eq(wednesday)
    expect(entry.email).to eq("booth@example.com")
    expect(entry.name).to eq("booth")
    expect(entry.data).to include("download_lead_id" => DownloadLead.last.id)
    expect(entry.data["utm"]).to eq("utm_campaign" => "ctg-2026")
  end

  it "keeps the lead's name when one was supplied" do
    travel_to central("2026-10-21 12:00") do
      post "/api/download_leads", params: ctg_params(email: "named@example.com", name: "Sam Booth")
    end

    expect(ContestEntry.last.name).to eq("Sam Booth")
  end

  # 23:30 CT on Oct 20 is 04:30 UTC on Oct 21. The event's own time zone, not
  # the server's, decides the calendar day.
  it "uses the event's time zone, so a 23:30 CT entry lands on the Tuesday event" do
    at = central("2026-10-20 23:30")
    expect(at.utc.to_date.iso8601).to eq("2026-10-21")

    travel_to at do
      post "/api/download_leads", params: ctg_params(email: "latenight@example.com")

      expect(JSON.parse(response.body).dig("drawing", "event_name"))
        .to eq("CTG 2026 Drawing — Tue Oct 20")
    end

    expect(ContestEntry.last.event).to eq(tuesday)
  end

  it "does not enter a lead whose source has no drawing" do
    travel_to central("2026-10-21 12:00") do
      expect {
        post "/api/download_leads", params: {
          download_lead: { email: "free@example.com", source: "free_download" },
        }
      }.not_to change(ContestEntry, :count)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      # Contract: `drawing` is absent when no drawing is configured, and the
      # frontend reads a missing `drawing` as "not entered".
      expect(body).not_to have_key("drawing")
      expect(body.dig("drawing", "entered")).to be_falsey
    end
  end

  it "still returns 201 with no drawing key when no ctg event is configured today" do
    travel_to central("2026-10-23 09:00") do
      expect {
        post "/api/download_leads", params: ctg_params(email: "afterparty@example.com")
      }.to change(DownloadLead, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body).not_to have_key("drawing")
      expect(body.dig("drawing", "entered")).to be_falsey
    end

    expect(ContestEntry.count).to eq(0)
  end

  it "enters the same person once per day, regardless of email casing" do
    travel_to central("2026-10-21 12:00") do
      post "/api/download_leads", params: ctg_params(email: "repeat@example.com")
      expect(JSON.parse(response.body).dig("drawing", "entered")).to eq(true)

      expect {
        post "/api/download_leads", params: ctg_params(email: "REPEAT@Example.COM")
      }.not_to change(ContestEntry, :count)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["drawing"]).to eq(
        "entered" => true,
        "event_name" => "CTG 2026 Drawing — Wed Oct 21",
      )
    end

    expect(wednesday.contest_entries.count).to eq(1)
  end

  it "enters the same person on each separate day of the series" do
    travel_to central("2026-10-20 10:00") do
      post "/api/download_leads", params: ctg_params(email: "loyal@example.com")
    end
    travel_to central("2026-10-21 10:00") do
      post "/api/download_leads", params: ctg_params(email: "loyal@example.com")
    end

    expect(tuesday.contest_entries.count).to eq(1)
    expect(wednesday.contest_entries.count).to eq(1)
  end

  # The bundle email matters more than the drawing.
  it "never fails the lead when entering the drawing raises" do
    allow_any_instance_of(ContestEntry).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.logger).to receive(:error)

    travel_to central("2026-10-21 12:00") do
      expect {
        post "/api/download_leads", params: ctg_params(email: "unlucky@example.com")
      }.to change(DownloadLead, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["drawing"]).to eq("entered" => false)
    end

    expect(ContestEntry.count).to eq(0)
    expect(MailchimpUpsertLeadJob.jobs.size).to eq(1)
    expect(Rails.logger).to have_received(:error).with(/Drawings::EnterLead/).at_least(:once)
  end

  # Staff/test entries go in and are excluded at draw time (#909), so the whole
  # flow can be tested end to end on prod.
  it "lets a staff address in but flags it excluded" do
    travel_to central("2026-10-21 12:00") do
      post "/api/download_leads", params: ctg_params(email: "someone@speakanyway.com")
    end

    entry = ContestEntry.last
    expect(entry).to be_excluded
    expect(entry).not_to be_eligible
    expect(JSON.parse(response.body).dig("drawing", "entered")).to eq(true)
  end
end
