require "rails_helper"

# The sibling of docs_update_authorization_spec.rb. #update got its owner/admin
# gate in #469; #destroy was missed and kept loading through
# `Doc.unscoped.find`, so any authenticated user could delete any doc —
# including the shared library art thousands of boards fall back to.
#
# The soft-delete branch was separately dead: it called `@doc.hide`, and the
# model defines only `hide!`.
RSpec.describe "API::Docs#destroy authorization", type: :request do
  let!(:owner)      { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }

  let!(:doc) { create(:doc, user: owner) }

  it "rejects a non-owner with 403 and leaves the doc alone" do
    delete "/api/docs/#{doc.id}", headers: auth_headers(other_user)

    expect(response).to have_http_status(:forbidden)
    expect(Doc.unscoped.find(doc.id).deleted_at).to be_nil
  end

  it "rejects an unauthenticated request with 401" do
    delete "/api/docs/#{doc.id}"

    expect(response).to have_http_status(:unauthorized)
    expect(Doc.unscoped.find(doc.id)).to be_present
  end

  it "refuses to let a stranger delete shared library art" do
    library_doc = create(:doc, user_id: nil)

    delete "/api/docs/#{library_doc.id}", headers: auth_headers(other_user)

    expect(response).to have_http_status(:forbidden)
    expect(Doc.unscoped.find(library_doc.id)).to be_present
  end

  it "soft-deletes for the owner instead of raising NoMethodError" do
    delete "/api/docs/#{doc.id}", headers: auth_headers(owner)

    expect(response).to have_http_status(:no_content)
    expect(Doc.unscoped.find(doc.id).deleted_at).to be_present
  end

  it "hard-deletes only when explicitly asked" do
    delete "/api/docs/#{doc.id}", params: { hard_delete: true }, headers: auth_headers(owner)

    expect(response).to have_http_status(:no_content)
    expect(Doc.unscoped.find_by(id: doc.id)).to be_nil
  end

  it "lets an admin delete any doc (cross-user access preserved)" do
    delete "/api/docs/#{doc.id}", headers: auth_headers(admin)

    expect(response).to have_http_status(:no_content)
    expect(Doc.unscoped.find(doc.id).deleted_at).to be_present
  end
end
