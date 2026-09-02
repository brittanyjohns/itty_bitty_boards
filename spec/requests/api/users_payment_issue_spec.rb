require "rails_helper"

# The past-due banner's payload (#826). The frontend never re-derives billing
# rules, so api_view answers "is there a payment problem, and what kind" in one
# field — nil whenever the account isn't past_due.
RSpec.describe "GET /api/users/:id (payment_issue)", type: :request do
  let(:user) { FactoryBot.create(:user, plan_type: "basic", plan_status: "active") }

  def show(target = user, as_user: target)
    get "/api/users/#{target.id}", headers: auth_headers(as_user), as: :json
    JSON.parse(response.body)
  end

  it "is nil when the account is not past_due" do
    body = show

    expect(response).to have_http_status(:ok)
    expect(body).to have_key("payment_issue")
    expect(body["payment_issue"]).to be_nil
  end

  it "reports the captured reason and the moment the account went past_due" do
    user.update!(plan_status: "past_due")
    user.update!(settings: user.settings.merge(
      User::PAYMENT_FAILURE_KEY => { "reason" => "bank_declined", "at" => Time.current.utc.iso8601 },
    ))

    issue = show["payment_issue"]

    expect(issue["reason"]).to eq("bank_declined")
    expect(Time.zone.parse(issue["since"])).to be_within(1.minute).of(Time.current)
  end

  it "falls back to generic for a past_due account with no captured reason" do
    user.update!(plan_status: "past_due")

    expect(show["payment_issue"]["reason"]).to eq("generic")
  end

  it "falls back to generic rather than raising on a junk stored value" do
    user.update!(plan_status: "past_due")
    user.update_column(:settings, user.settings.merge(User::PAYMENT_FAILURE_KEY => "corrupt"))

    expect(show["payment_issue"]["reason"]).to eq("generic")
  end

  it "goes back to nil once the account recovers" do
    user.update!(plan_status: "past_due")
    user.update!(settings: user.settings.merge(
      User::PAYMENT_FAILURE_KEY => { "reason" => "expired_card", "at" => Time.current.utc.iso8601 },
    ))
    user.update!(plan_status: "active")

    expect(show["payment_issue"]).to be_nil
  end
end
