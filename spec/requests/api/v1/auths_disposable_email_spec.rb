require "rails_helper"

RSpec.describe "disposable email rejection", type: :request do
  it "rejects a disposable address at standard signup" do
    post "/api/v1/users",
         params: { email: "throwaway@mailinator.com", password: "password123",
                   password_confirmation: "password123" },
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to be_present
    expect(User.find_by(email: "throwaway@mailinator.com")).to be_nil
  end

  it "rejects a disposable address at email signup" do
    post "/api/v1/users/email_signup", params: { email: "throwaway@mailinator.com" }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(User.find_by(email: "throwaway@mailinator.com")).to be_nil
  end
end
