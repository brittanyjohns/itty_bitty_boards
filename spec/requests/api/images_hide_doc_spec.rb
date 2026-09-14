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

  # src_url is SHARED — every tile created from the image snapshots it. Hiding
  # the default used to promote whichever doc was newest, which could be some
  # other user's private upload, publishing it as the library art.
  it "never promotes another user's private doc into the shared src_url" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    library_image = create(:image, user: admin, label: "moon")
    older_library_doc = create(:doc, documentable: library_image, user: admin)
    default_doc = create(:doc, documentable: library_image, user: admin, current: true)
    create(:doc, documentable: library_image, user: create(:user))
    allow_any_instance_of(Doc).to receive(:tile_url) { |d| "https://cdn.example.com/doc_#{d.id}.webp" }
    library_image.update_column(:src_url, default_doc.tile_url)

    post "/api/images/#{library_image.id}/hide_doc",
         params: { doc_id: default_doc.id },
         headers: auth_headers(admin)

    expect(library_image.reload.src_url).to eq(older_library_doc.tile_url)
  end
end
