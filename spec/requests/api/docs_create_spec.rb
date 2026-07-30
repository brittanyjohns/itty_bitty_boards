require "rails_helper"

# API::DocsController#create's JSON branch was `render :show, location: @doc`.
# Two faults, both firing only AFTER the Doc was saved: `location: @doc` resolves
# to `doc_url`, but the route is declared inside `namespace :api` so the helper is
# `api_doc_url`; and there is no app/views/api/docs/show template for `render :show`
# to find. The record was created and the client got a 500. These specs pin the
# JSON create path to a real 201 + api_view body.
RSpec.describe "API::Docs#create", type: :request do
  let!(:user)  { create(:user) }
  let!(:image) { create(:image) }

  let(:upload) do
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files/sample.png"), "image/png"
    )
  end

  def create_doc(params, headers = auth_headers(user))
    post "/api/docs", params: { doc: params }, headers: headers
  end

  it "returns 201 with the doc's api_view instead of 500ing" do
    expect {
      create_doc(documentable_id: image.id, documentable_type: "Image", image: upload)
    }.to change(Doc, :count).by(1)

    expect(response).to have_http_status(:created)

    body = JSON.parse(response.body)
    doc  = Doc.last
    expect(body["id"]).to eq(doc.id)
    expect(body["documentable_id"]).to eq(image.id)
    expect(body["documentable_type"]).to eq("Image")
    expect(body["user_id"]).to eq(user.id)
  end

  it "sets a Location header built from the api-namespaced route helper" do
    create_doc(documentable_id: image.id, documentable_type: "Image", image: upload)

    expect(response).to have_http_status(:created)
    expect(response.headers["Location"]).to end_with("/api/docs/#{Doc.last.id}")
  end

  it "assigns the doc to the current user and links a UserDoc" do
    create_doc(documentable_id: image.id, documentable_type: "Image", image: upload)

    doc = Doc.last
    expect(doc.user).to eq(user)
    expect(UserDoc.find_by(doc_id: doc.id, user_id: user.id, image_id: image.id)).to be_present
  end

  it "carries source_type through when supplied" do
    create_doc(
      documentable_id: image.id,
      documentable_type: "Image",
      image: upload,
      source_type: "OpenSymbol",
    )

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["source_type"]).to eq("OpenSymbol")
  end

  it "rejects an unauthenticated request without creating a doc" do
    expect {
      post "/api/docs",
           params: { doc: { documentable_id: image.id, documentable_type: "Image", image: upload } }
    }.not_to change(Doc, :count)

    expect(response).to have_http_status(:unauthorized)
  end
end
