require "rails_helper"

RSpec.describe "Admin::PrintableProductSceneCompositions (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:product) { create_printable_product(artwork_count: 2) }
  let(:template) { create_device_tag_template(name: "Two tags on a desk") }
  let(:first_artwork) { product.artwork_blob_ids.first }
  let(:second_artwork) { product.artwork_blob_ids.last }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    allow(RenderSceneCompositionJob).to receive(:perform_async)
  end

  # The form posts the artwork choice as artwork_blob_id, mapped onto blob_id.
  def artwork_art(a = first_artwork, b = second_artwork)
    {
      "tag_a" => { "source" => "product_artwork", "artwork_blob_id" => a.to_s },
      "tag_b" => { "source" => "product_artwork", "artwork_blob_id" => b.to_s },
    }
  end

  it "refuses a non-admin" do
    sign_in create(:user)

    get new_admin_dashboard_printable_product_scene_composition_path(product)
    expect(response).to redirect_to(root_path)

    post admin_dashboard_printable_product_scene_compositions_path(product),
         params: { scene_composition: { scene_template_id: template.id }, slot_art: artwork_art }
    expect(SceneComposition.count).to eq(0)
  end

  describe "GET new" do
    it "offers only calibrated templates in the product's category" do
      sign_in admin
      template
      create_scene_template(name: "A board scene")
      create_device_tag_template(name: "Uncalibrated tags", status: "draft")

      get new_admin_dashboard_printable_product_scene_composition_path(product)

      expect(response.body).to include("Two tags on a desk")
      expect(response.body).not_to include("A board scene")
      expect(response.body).not_to include("Uncalibrated tags")
    end

    it "offers the product's artworks by label and no board picker" do
      sign_in admin

      get new_admin_dashboard_printable_product_scene_composition_path(product, scene_template_id: template.id)

      expect(response.body).to include('name="slot_art[tag_a][artwork_blob_id]"', "Voice Tag 1", "Voice Tag 2", "Product artwork")
      expect(response.body).not_to include('name="slot_art[tag_a][board_id]"')
      expect(response.body).not_to include("Printed page")
    end
  end

  describe "POST create" do
    it "saves each slot's artwork and renders on request" do
      sign_in admin

      post admin_dashboard_printable_product_scene_compositions_path(product),
           params: { scene_composition: { scene_template_id: template.id }, slot_art: artwork_art, render: "1" }

      composition = product.scene_compositions.last
      expect(response).to redirect_to(edit_admin_dashboard_printable_product_scene_composition_path(product, composition))
      expect(composition.slot_art).to eq(
        "tag_a" => { "source" => "product_artwork", "blob_id" => first_artwork },
        "tag_b" => { "source" => "product_artwork", "blob_id" => second_artwork },
      )
      expect(RenderSceneCompositionJob).to have_received(:perform_async).with(composition.id)
    end

    it "refuses another product's artwork" do
      sign_in admin
      stranger = create_printable_product(artwork_count: 1)

      post admin_dashboard_printable_product_scene_compositions_path(product),
           params: { scene_composition: { scene_template_id: template.id }, slot_art: artwork_art(stranger.artwork_blob_ids.first) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(SceneComposition.count).to eq(0)
    end

    it "won't take a board scene even when its id is posted" do
      sign_in admin
      board_scene = create_scene_template

      post admin_dashboard_printable_product_scene_compositions_path(product),
           params: { scene_composition: { scene_template_id: board_scene.id }, slot_art: {} }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(SceneComposition.count).to eq(0)
    end
  end

  describe "an existing composition" do
    let!(:composition) do
      SceneComposition.create!(owner: product, scene_template: template, slot_art: {
        "tag_a" => { "source" => "product_artwork", "blob_id" => first_artwork },
      })
    end

    it "updates a slot to another artwork" do
      sign_in admin

      patch admin_dashboard_printable_product_scene_composition_path(product, composition),
            params: { slot_art: { "tag_a" => { "source" => "product_artwork", "artwork_blob_id" => second_artwork.to_s } } }

      expect(composition.reload.slot_art["tag_a"]["blob_id"]).to eq(second_artwork)
    end

    it "shows the render with a download link" do
      sign_in admin
      composition.attach_render!(bytes: "jpeg-bytes", digest: composition.current_render_digest)

      get edit_admin_dashboard_printable_product_scene_composition_path(product, composition)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Rendered scene mockup", "Download JPEG", product.name)
    end

    it "queues a render" do
      sign_in admin

      post render_scene_admin_dashboard_printable_product_scene_composition_path(product, composition)

      expect(RenderSceneCompositionJob).to have_received(:perform_async).with(composition.id)
    end

    it "can't be reached through a different product" do
      sign_in admin
      elsewhere = create_printable_product

      get edit_admin_dashboard_printable_product_scene_composition_path(elsewhere, composition)

      expect(response).to have_http_status(:not_found)
    end

    it "deletes back to the product" do
      sign_in admin

      delete admin_dashboard_printable_product_scene_composition_path(product, composition)

      expect(response).to redirect_to(admin_dashboard_printable_product_path(product))
      expect(SceneComposition.exists?(composition.id)).to be(false)
    end
  end
end
