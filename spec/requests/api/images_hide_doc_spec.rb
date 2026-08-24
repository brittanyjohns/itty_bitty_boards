require "rails_helper"

# `hide_doc` is the endpoint the frontend's trash icon calls. It took a
# `hard_delete` param, but the line above it ran `@image.docs.delete(@doc)` —
# and because `has_many :docs` is `dependent: :destroy`, `.delete` DESTROYS.
# So every "hide" was really a permanent delete, the soft branch ran against an
# already-destroyed record, and a rescue for FrozenError hid the damage.
RSpec.describe "API::Images#hide_doc", type: :request do
  let!(:owner) { create(:user) }
  let!(:image) { create(:image, user: owner) }
  let!(:doc)   { create(:doc, documentable: image, user: owner) }

  it "soft-deletes by default so the doc is recoverable" do
    post "/api/images/#{image.id}/hide_doc",
         params: { doc_id: doc.id },
         headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    persisted = Doc.unscoped.find_by(id: doc.id)
    expect(persisted).to be_present
    expect(persisted.deleted_at).to be_present
  end

  it "hard-deletes only when explicitly asked" do
    post "/api/images/#{image.id}/hide_doc",
         params: { doc_id: doc.id, hard_delete: true },
         headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    expect(Doc.unscoped.find_by(id: doc.id)).to be_nil
  end

  it "refuses a doc the caller does not own" do
    stranger = create(:user)

    post "/api/images/#{image.id}/hide_doc",
         params: { doc_id: doc.id },
         headers: auth_headers(stranger)

    expect(Doc.unscoped.find(doc.id).deleted_at).to be_nil
  end
end
