require "rails_helper"

RSpec.describe "API::Admin::Events", type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:event) { FactoryBot.create(:event, name: "Spring Giveaway 2026", slug: "spring-giveaway-2026") }
  let!(:loser) { FactoryBot.create(:contest_entry, event: event, name: "Loser", email: "loser@example.com") }
  let!(:winner) { FactoryBot.create(:contest_entry, event: event, name: "Winner", email: "winner@example.com", winner: true) }

  describe "GET /api/admin/events/:id_or_slug" do
    it "returns the admin view, including entries and winner fields" do
      get "/api/admin/events/#{event.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.keys).to include(
        "id", "name", "slug", "date", "promo_code", "promo_code_details", "public_url",
        "created_at", "updated_at", "entries_count", "winner", "winner_name",
        "winner_email", "contest_entries"
      )
      expect(body["entries_count"]).to eq(2)
      expect(body["winner_name"]).to eq("Winner")
      expect(body["winner_email"]).to eq("winner@example.com")
      expect(body["winner"]["id"]).to eq(winner.id)
      expect(body["contest_entries"].map { |e| e["email"] })
        .to match_array(%w[loser@example.com winner@example.com])
      expect(body["contest_entries"].first.keys).to match_array(
        %w[id name email data event_id winner won_at excluded created_at updated_at],
      )
    end

    it "orders contest_entries newest first" do
      older = FactoryBot.create(:contest_entry, event: event, email: "older@example.com", created_at: 3.days.ago)
      newer = FactoryBot.create(:contest_entry, event: event, email: "newer@example.com", created_at: 1.minute.ago)

      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      ids = JSON.parse(response.body)["contest_entries"].map { |e| e["id"] }
      expect(ids.index(newer.id)).to be < ids.index(older.id)
    end

    it "resolves the event by slug as well as by id" do
      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(event.id)
    end

    it "reports no winner as null when nobody has been drawn" do
      event.contest_entries.update_all(winner: false)

      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["winner"]).to be_nil
      expect(body["winner_name"]).to be_nil
      expect(body["winner_email"]).to be_nil
    end

    it "404s with the exact not_found error when neither a slug nor an id matches" do
      get "/api/admin/events/no-such-event", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end

    it "401s with the exact Unauthorized error without a token" do
      get "/api/admin/events/#{event.slug}"

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq({ "error" => "Unauthorized" })
      expect(response.body).not_to include("winner@example.com")
    end

    it "401s for a signed-in non-admin" do
      get "/api/admin/events/#{event.slug}", headers: auth_headers(FactoryBot.create(:user))

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include("winner@example.com")
    end
  end

  describe "POST /api/admin/events" do
    it "creates the event and returns the admin view with a 201" do
      expect {
        post "/api/admin/events",
             params: { event: { name: "CTG Day One", date: "2026-10-20", lead_source: "ctg",
                                time_zone: "America/Chicago", promo_code: "CTG25" } },
             headers: auth_headers(admin)
      }.to change { Event.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("CTG Day One")
      expect(body["slug"]).to eq("ctg-day-one")
      expect(body["lead_source"]).to eq("ctg")
      expect(body["time_zone"]).to eq("America/Chicago")
      expect(body["entries_count"]).to eq(0)
      expect(body["eligible_count"]).to eq(0)
      expect(body["contest_entries"]).to eq([])
    end

    # The old create called @event.save twice — once for the body, once for the
    # status — which still only inserted one row, so a row-count assertion can't
    # see the bug. Count the save calls instead. #909 item 5.
    it "saves exactly once" do
      expect_any_instance_of(Event).to receive(:save).once.and_call_original

      post "/api/admin/events",
           params: { event: { name: "Only Once", date: "2026-10-20" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(Event.where(slug: "only-once").count).to eq(1)
    end

    it "422s with field errors when the event is invalid" do
      post "/api/admin/events", params: { event: { name: "" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["errors"]["name"]).to include("can't be blank")
    end

    it "401s without an admin token" do
      post "/api/admin/events", params: { event: { name: "Nope" } }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq({ "error" => "Unauthorized" })
    end
  end

  describe "PATCH /api/admin/events/:id_or_slug" do
    it "updates and returns the event JSON instead of 500ing on a missing template" do
      patch "/api/admin/events/#{event.slug}",
            params: { event: { name: "Renamed Giveaway", lead_source: "ctg" } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Renamed Giveaway")
      expect(body["lead_source"]).to eq("ctg")
      expect(body["entries_count"]).to eq(2)
      expect(event.reload.name).to eq("Renamed Giveaway")
    end

    it "422s with field errors when the update is invalid" do
      patch "/api/admin/events/#{event.slug}",
            params: { event: { name: "" } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["errors"]["name"]).to include("can't be blank")
    end

    it "404s for an unknown id or slug" do
      patch "/api/admin/events/no-such-event",
            params: { event: { name: "x" } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end
  end

  describe "POST /api/admin/events/:id_or_slug/pick_winner" do
    let(:drawing) { FactoryBot.create(:event, name: "CTG Day One", slug: "ctg-day-one", lead_source: "ctg") }

    it "422s with no_eligible_entries when the event has no entries" do
      post "/api/admin/events/#{drawing.slug}/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq({ "error" => "no_eligible_entries" })
    end

    it "422s when every entry is staff or test" do
      FactoryBot.create(:contest_entry, event: drawing, email: "brittany@speakanyway.com")
      FactoryBot.create(:contest_entry, event: drawing, email: "bhannajohns@gmail.com")

      post "/api/admin/events/#{drawing.slug}/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq({ "error" => "no_eligible_entries" })
      expect(drawing.contest_entries.where(winner: true)).to be_empty
    end

    it "honours DRAWING_EXCLUDED_EMAILS" do
      FactoryBot.create(:contest_entry, event: drawing, email: "tester@example.com")

      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("DRAWING_EXCLUDED_EMAILS", "").and_return("Tester@Example.com")

      post "/api/admin/events/#{drawing.slug}/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq({ "error" => "no_eligible_entries" })
    end

    it "draws a winner, stamps won_at, and returns the admin view" do
      entry = FactoryBot.create(:contest_entry, event: drawing, email: "ada@example.com")

      post "/api/admin/events/#{drawing.slug}/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["winner"]["id"]).to eq(entry.id)
      expect(body["winner"]["won_at"]).to be_present
      expect(body["winner_email"]).to eq("ada@example.com")
      expect(entry.reload.winner).to be(true)
      expect(entry.won_at).to be_present
    end

    it "409s with already_drawn when the event already has a winner" do
      post "/api/admin/events/#{event.slug}/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("already_drawn")
      expect(body["winner"]["id"]).to eq(winner.id)
      expect(winner.reload.winner).to be(true)
    end

    it "picks a new winner on redraw: true and leaves the old winner's won_at intact" do
      drawn_at = 1.hour.ago
      winner.update!(won_at: drawn_at)
      challenger = FactoryBot.create(:contest_entry, event: event, email: "challenger@example.com")

      post "/api/admin/events/#{event.slug}/pick_winner",
           params: { redraw: true }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["winner"]["id"]).not_to eq(winner.id)
      expect([loser.id, challenger.id]).to include(body["winner"]["id"])

      winner.reload
      expect(winner.winner).to be(false)
      expect(winner.won_at).to be_within(1.second).of(drawn_at)
      expect(winner.data["redrawn_at"]).to be_present
    end

    it "never draws an ineligible entry" do
      eligible = FactoryBot.create(:contest_entry, event: drawing, email: "eligible@example.com")
      staff = FactoryBot.create(:contest_entry, event: drawing, email: "staff@speakanyway.com")
      flagged = FactoryBot.create(:contest_entry, event: drawing, email: "flagged@example.com")
      flagged.update!(excluded: true)

      other_day = FactoryBot.create(:event, slug: "ctg-day-two", lead_source: "ctg")
      FactoryBot.create(:contest_entry, event: other_day, email: "repeat@example.com",
                                        winner: false, won_at: 1.day.ago)
      repeat = FactoryBot.create(:contest_entry, event: drawing, email: "repeat@example.com")

      10.times do
        drawing.contest_entries.update_all(winner: false, won_at: nil)

        post "/api/admin/events/#{drawing.slug}/pick_winner",
             params: { redraw: true }, headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["winner"]["id"]).to eq(eligible.id)
      end

      expect([staff.id, flagged.id, repeat.id]).not_to include(eligible.id)
    end

    it "treats an absent body as redraw: false" do
      post "/api/admin/events/#{event.slug}/pick_winner", headers: auth_headers(admin)
      expect(response).to have_http_status(:conflict)
    end

    it "404s for an unknown event" do
      post "/api/admin/events/no-such-event/pick_winner", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end

    it "401s without an admin token" do
      post "/api/admin/events/#{event.slug}/pick_winner"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/admin/events/:event_id/entries/:id" do
    it "removes the entry for an admin" do
      expect {
        delete "/api/admin/events/#{event.slug}/entries/#{loser.id}", headers: auth_headers(admin)
      }.to change { event.contest_entries.count }.by(-1)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "success" => true })
    end

    it "requires an admin" do
      expect {
        delete "/api/admin/events/#{event.slug}/entries/#{loser.id}"
      }.not_to(change { event.contest_entries.count })

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq({ "error" => "Unauthorized" })
    end

    it "401s for a signed-in non-admin" do
      expect {
        delete "/api/admin/events/#{event.slug}/entries/#{loser.id}",
               headers: auth_headers(FactoryBot.create(:user))
      }.not_to(change { event.contest_entries.count })

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s for an entry that belongs to another event" do
      other = FactoryBot.create(:contest_entry, email: "other@example.com",
                                                event: FactoryBot.create(:event))

      delete "/api/admin/events/#{event.slug}/entries/#{other.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
      expect(ContestEntry.exists?(other.id)).to be(true)
    end

    it "404s for an unknown event" do
      delete "/api/admin/events/no-such-event/entries/#{loser.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end
  end

  describe "GET /api/admin/events/:id_or_slug/download_entries" do
    it "returns a CSV whose header row is the full column list" do
      winner.update!(won_at: Time.current)

      get "/api/admin/events/#{event.slug}/download_entries", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      header = CSV.parse(response.body).first
      expect(header).to eq(ContestEntry.column_names)
      expect(header).to include("won_at", "data", "winner", "excluded")
      expect(response.body).to include("winner@example.com")
    end
  end

  describe "entry email normalization" do
    it "rejects the same email in a different case on the same event" do
      post "/api/events/#{event.slug}/save_entry",
           params: { contest_entry: { name: "Jane", email: "Jane@X.com" } }
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["entry"]["email"]).to eq("jane@x.com")

      expect {
        post "/api/events/#{event.slug}/save_entry",
             params: { contest_entry: { name: "Jane Again", email: " jane@x.com " } }
      }.not_to(change { event.contest_entries.count })

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["errors"]["email"]).to include("has already entered this event")
    end

    it "flags a staff address as excluded on save" do
      post "/api/events/#{event.slug}/save_entry",
           params: { contest_entry: { name: "Staff", email: "Staff@SpeakAnyWay.com" } }

      expect(response).to have_http_status(:created)
      entry = JSON.parse(response.body)["entry"]
      expect(entry["email"]).to eq("staff@speakanyway.com")
      expect(entry["excluded"]).to be(true)
    end
  end
end
