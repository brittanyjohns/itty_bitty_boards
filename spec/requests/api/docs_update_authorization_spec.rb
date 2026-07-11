require "rails_helper"

# Issue #469 (broken access control): API::DocsController#set_doc loads the doc
# with `Doc.unscoped.find` and #update had no owner/admin gate, so any
# authenticated user could mutate any doc's content. These specs prove the
# non-owner path is now rejected (403) and the owner/admin paths still work,
# and that the JSON success path renders instead of 500ing on a missing view.
RSpec.describe "API::Docs#update authorization", type: :request do
  let!(:owner)      { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }

  let!(:doc) { create(:doc, user: owner, raw: "original") }

  it "rejects a non-owner with 403 and does not mutate the doc" do
    patch "/api/docs/#{doc.id}",
          params: { doc: { raw: "hacked" } },
          headers: auth_headers(other_user)

    expect(response).to have_http_status(:forbidden)
    expect(doc.reload.raw).to eq("original")
  end

  it "rejects an unauthenticated request with 401" do
    patch "/api/docs/#{doc.id}", params: { doc: { raw: "hacked" } }

    expect(response).to have_http_status(:unauthorized)
    expect(doc.reload.raw).to eq("original")
  end

  it "lets the owner update and renders JSON (no 500 on the success path)" do
    patch "/api/docs/#{doc.id}",
          params: { doc: { raw: "updated" } },
          headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["id"]).to eq(doc.id)
    expect(body["raw"]).to eq("updated")
    expect(doc.reload.raw).to eq("updated")
  end

  it "lets an admin update any doc (cross-user access preserved)" do
    patch "/api/docs/#{doc.id}",
          params: { doc: { raw: "admin edit" } },
          headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(doc.reload.raw).to eq("admin edit")
  end
end
