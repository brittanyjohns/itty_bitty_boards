require "rails_helper"

RSpec.describe "Admin::PrintableProducts (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  def product_params(**overrides)
    { printable_product: { name: "AAC Device Tags", slug: "", category: "device_tag", size_label: "2.5 x 2 in", status: "draft" }.merge(overrides) }
  end

  it "refuses a non-admin" do
    sign_in create(:user)

    get admin_dashboard_printable_products_path
    expect(response).to redirect_to(root_path)

    post admin_dashboard_printable_products_path, params: product_params
    expect(PrintableProduct.count).to eq(0)
  end

  describe "index" do
    it "lists active products and hides archived ones by default" do
      sign_in admin
      create_printable_product(name: "Live Tags")
      create_printable_product(name: "Old Tags", status: "archived")

      get admin_dashboard_printable_products_path
      expect(response.body).to include("Live Tags")
      expect(response.body).not_to include("Old Tags")

      get admin_dashboard_printable_products_path(status: "archived")
      expect(response.body).to include("Old Tags")
    end
  end

  describe "create" do
    it "derives the slug and keeps filled Canva rows only" do
      sign_in admin

      post admin_dashboard_printable_products_path, params: product_params.merge(
        canva_templates: [
          { label: "Voice Tag 1", url: "https://canva.link/voice1", description: "" },
          { label: "", url: "", description: "" },
        ],
      )

      product = PrintableProduct.last
      expect(response).to redirect_to(admin_dashboard_printable_product_path(product))
      expect(product.slug).to eq("aac-device-tags")
      expect(product.canva_templates).to eq([{ "label" => "Voice Tag 1", "url" => "https://canva.link/voice1", "description" => "" }])
    end

    it "re-renders with the validator's message for a non-Canva link" do
      sign_in admin

      post admin_dashboard_printable_products_path, params: product_params.merge(
        canva_templates: [{ label: "Tag", url: "https://example.com/design/x" }],
      )

      expect(response).to have_http_status(:unprocessable_entity)
      expect(CGI.unescapeHTML(response.body)).to include("canva.link/… link")
      expect(PrintableProduct.count).to eq(0)
    end
  end

  describe "an existing product" do
    let!(:product) { create_printable_product(name: "Tags") }

    it "updates" do
      sign_in admin

      patch admin_dashboard_printable_product_path(product), params: product_params(name: "Tags v2", slug: "tags", status: "ready")

      expect(product.reload).to have_attributes(name: "Tags v2", status: "ready")
    end

    it "archives" do
      sign_in admin

      post archive_admin_dashboard_printable_product_path(product)

      expect(product.reload).to be_archived
    end

    it "uploads a labelled artwork and shows it" do
      sign_in admin

      post upload_artwork_admin_dashboard_printable_product_path(product),
           params: { artwork: uploaded_scene_png(250, 200, filename: "voice.png"), label: "Voice Tag 1" }

      expect(response).to redirect_to(admin_dashboard_printable_product_path(product))
      expect(product.reload.artworks.first.metadata["label"]).to eq("Voice Tag 1")

      get admin_dashboard_printable_product_path(product)
      expect(response.body).to include("Voice Tag 1", "Scene mockups")
    end

    it "refuses an artwork outside the allowlist with a flash, attaching nothing" do
      sign_in admin

      expect do
        post upload_artwork_admin_dashboard_printable_product_path(product),
             params: { artwork: Rack::Test::UploadedFile.new(StringIO.new("GIF89a"), "image/gif", original_filename: "x.gif") }
      end.not_to change(ActiveStorage::Blob, :count)

      expect(flash[:alert]).to include("image/gif")
    end

    it "uploads and removes a download" do
      sign_in admin

      post upload_download_admin_dashboard_printable_product_path(product),
           params: { download: Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4"), "application/pdf", original_filename: "tags.pdf") }
      file = product.reload.downloads.first
      expect(file.filename.to_s).to eq("tags.pdf")
      expect(product.artworks).not_to be_attached

      delete remove_download_admin_dashboard_printable_product_path(product), params: { signed_id: file.signed_id }
      expect(product.reload.downloads).not_to be_attached
    end

    it "refuses to remove an artwork a scene mockup draws, and removes one no mockup uses" do
      sign_in admin
      product = create_printable_product(artwork_count: 2)
      used, unused = product.ordered_artworks
      composition = SceneComposition.create!(owner: product, scene_template: create_device_tag_template,
                                             slot_art: { "tag_a" => { "source" => "product_artwork", "blob_id" => used.blob_id } })

      delete remove_artwork_admin_dashboard_printable_product_path(product), params: { signed_id: used.signed_id }
      expect(flash[:alert]).to include("##{composition.id}")
      expect(product.reload.artwork_blob_ids).to include(used.blob_id)

      delete remove_artwork_admin_dashboard_printable_product_path(product), params: { signed_id: unused.signed_id }
      expect(product.reload.artwork_blob_ids).not_to include(unused.blob_id)
    end
  end
end
