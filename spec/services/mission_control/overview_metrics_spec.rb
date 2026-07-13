require "rails_helper"

RSpec.describe MissionControl::OverviewMetrics do
  describe ".call" do
    # Freeze to midday UTC so "today" rows seeded with `1.hour.ago` can't slip
    # into yesterday's calendar-day bucket when the suite happens to run in the
    # hour after midnight — the daily breakdown and the day-window counts both
    # bucket by Time.zone calendar day. DB-only spec, so the Redis/`travel_to`
    # TTL caveat doesn't apply.
    around { |example| travel_to(Time.utc(2026, 6, 23, 12, 0, 0)) { example.run } }

    let!(:admin) { create(:user, role: "admin", created_at: 1.hour.ago) }
    let!(:user_today) { create(:user, created_at: 1.hour.ago, last_sign_in_at: 1.hour.ago) }
    let!(:user_3d) { create(:user, created_at: 3.days.ago, last_sign_in_at: 3.days.ago) }
    let!(:user_10d) { create(:user, created_at: 10.days.ago, last_sign_in_at: 10.days.ago) }
    let!(:user_old) { create(:user, created_at: 60.days.ago, last_sign_in_at: 60.days.ago) }
    let!(:trialing_user) { create(:user, created_at: 2.days.ago, plan_status: "trialing") }

    subject(:result) { described_class.call }

    it "counts signups excluding admins" do
      expect(result[:signups_today]).to eq(1)
      expect(result[:signups_7d]).to eq(3)
      expect(result[:signups_30d]).to eq(4)
    end

    it "counts active users by sign-in recency" do
      expect(result[:active_users_7d]).to eq(2)
      expect(result[:active_users_30d]).to eq(3)
    end

    it "counts trial users" do
      expect(result[:trial_users]).to eq(1)
    end

    it "returns total non-admin user count" do
      expect(result[:total_users]).to eq(5)
    end

    it "returns daily signup breakdown for last 7 days" do
      daily = result[:signups_daily_7d]
      expect(daily).to be_a(Hash)
      today_key = Time.zone.today.to_s
      expect(daily[today_key]).to eq(1)
    end

    it "returns board and word event counts" do
      expect(result).to have_key(:boards_today)
      expect(result).to have_key(:boards_7d)
      expect(result).to have_key(:total_boards)
      expect(result).to have_key(:word_events_today)
      expect(result).to have_key(:word_events_7d)
    end

    it "returns communicator and profile counts" do
      expect(result).to have_key(:communicator_accounts)
      expect(result).to have_key(:myspeak_profiles)
    end

    context "with demo accounts" do
      let!(:demo_user) do
        create(:user, email: "bhannajohns+metrics@gmail.com",
                      created_at: 1.hour.ago, last_sign_in_at: 1.hour.ago)
      end
      let!(:demo_board) { create(:board, user: demo_user, created_at: 1.hour.ago) }
      let!(:demo_word_event) { create(:word_event, user: demo_user, created_at: 1.hour.ago) }
      let!(:demo_communicator) { create(:child_account, user: demo_user) }
      let!(:real_board) { create(:board, user: user_today, created_at: 1.hour.ago) }

      it "excludes demo users from signup and activity counts" do
        expect(result[:signups_today]).to eq(1)
        expect(result[:total_users]).to eq(5)
        expect(result[:active_users_7d]).to eq(2)
        expect(result[:signups_daily_7d][Time.zone.today.to_s]).to eq(1)
      end

      it "excludes demo-owned boards, word events, and communicators" do
        expect(result[:total_boards]).to eq(1)
        expect(result[:boards_today]).to eq(1)
        expect(result[:word_events_today]).to eq(0)
        expect(result[:communicator_accounts]).to eq(0)
      end
    end
  end
end
