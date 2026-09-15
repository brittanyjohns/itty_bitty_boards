require "rails_helper"

RSpec.describe "Admin::SceneCompositions (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id, other.id]) }
  let(:template) { create_scene_template(name: "Fridge pair") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    allow(RenderSceneCompositionJob).to receive(:perform_async)
  end

  def page_art(board_id)
    { "fridge" => { "source" => "page_thumbnail", "board_id" => board_id.to_s, "ink" => "color", "header" => "1" } }
  end

  it "redirects a non-admin" do
    sign_in create(:user)

    get new_admin_dashboard_board_printable_scene_composition_path(printable)
    expect(response).to redirect_to(root_path)

    post admin_dashboard_board_printable_scene_compositions_path(printable),
         params: { scene_composition: { scene_template_id: template.id }, slot_art: page_art(board.id) }
    expect(SceneComposition.count).to eq(0)
  end

  describe "GET new" do
    it "offers only calibrated board templates" do
      sign_in admin
      template
      create_scene_template(name: "Unfinished draft", status: "draft", slots: [])
      create_scene_template(name: "A device tag scene", category: "device_tag")

      get new_admin_dashboard_board_printable_scene_composition_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fridge pair")
      expect(response.body).not_to include("Unfinished draft")
      expect(response.body).not_to include("A device tag scene")
    end

    it "shows a slot picker once a template is chosen" do
      sign_in admin

      get new_admin_dashboard_board_printable_scene_composition_path(printable, scene_template_id: template.id)

      expect(response.body).to include('name="slot_art[fridge][source]"')
      expect(response.body).to include("Feelings")
    end
  end

  describe "POST create" do
    it "saves the art choice and renders on request" do
      sign_in admin

      post admin_dashboard_board_printable_scene_compositions_path(printable),
           params: { scene_composition: { scene_template_id: template.id }, slot_art: page_art(other.id), render: "1" }

      composition = printable.scene_compositions.last
      expect(response).to redirect_to(edit_admin_dashboard_board_printable_scene_composition_path(printable, composition))
      expect(composition.slot_art["fridge"]).to eq("source" => "page_thumbnail", "board_id" => other.id, "ink" => "color", "header" => true)
      expect(RenderSceneCompositionJob).to have_received(:perform_async).with(composition.id)
    end

    it "refuses a board from outside the printable" do
      sign_in admin
      stranger = create(:board, user: owner)

      post admin_dashboard_board_printable_scene_compositions_path(printable),
           params: { scene_composition: { scene_template_id: template.id }, slot_art: page_art(stranger.id) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(SceneComposition.count).to eq(0)
      expect(RenderSceneCompositionJob).not_to have_received(:perform_async)
    end

    it "attaches a picture uploaded for a slot and points the slot at it" do
      sign_in admin

      post admin_dashboard_board_printable_scene_compositions_path(printable), params: {
        scene_composition: { scene_template_id: template.id },
        slot_art: { "fridge" => { "source" => "" } },
        slot_files: { "fridge" => uploaded_scene_png(80, 60, filename: "photo.png") },
      }

      composition = printable.scene_compositions.last
      expect(composition.slot_uploads.size).to eq(1)
      expect(composition.slot_art["fridge"]).to eq("source" => "upload", "blob_id" => composition.slot_uploads.first.blob_id)
    end

    it "refuses an upload in a format outside the allowlist before saving anything" do
      sign_in admin

      post admin_dashboard_board_printable_scene_compositions_path(printable), params: {
        scene_composition: { scene_template_id: template.id },
        slot_files: { "fridge" => Rack::Test::UploadedFile.new(StringIO.new("GIF89a"), "image/gif", original_filename: "x.gif") },
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(SceneComposition.count).to eq(0)
    end
  end

  describe "the words in a template's text slots" do
    let(:worded) do
      create_scene_template(name: "Worded", slots: [scene_slot(key: "fridge")],
                            text_slots: [scene_text_slot(key: "headline", label: "Headline", max_chars: 20)],
                            overlay_regions: [scene_overlay])
    end

    it "offers one input per text slot, capped at max_chars" do
      sign_in admin

      get new_admin_dashboard_board_printable_scene_composition_path(printable, scene_template_id: worded.id)

      expect(response.body).to include('name="text_values[headline]"', 'maxlength="20"', 'placeholder="Printable AAC"')
      expect(response.body).to include("Up to 20 characters")
      expect(response.body).to include("feature list")
    end

    it "saves the words with the art" do
      sign_in admin

      post admin_dashboard_board_printable_scene_compositions_path(printable), params: {
        scene_composition: { scene_template_id: worded.id },
        slot_art: page_art(board.id),
        text_values: { "headline" => "Core Words", "not_a_slot" => "ignored" },
      }

      composition = printable.scene_compositions.last
      expect(composition.text_values).to eq("headline" => "Core Words")
      expect(composition.slot_art["fridge"]["board_id"]).to eq(board.id)
    end

    it "refuses words over the limit" do
      sign_in admin

      post admin_dashboard_board_printable_scene_compositions_path(printable), params: {
        scene_composition: { scene_template_id: worded.id },
        text_values: { "headline" => "x" * 21 },
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("over the 20-character limit")
      expect(SceneComposition.count).to eq(0)
    end

    it "clears the words back to the default when the field is blanked, and keeps them when it isn't sent" do
      sign_in admin
      composition = SceneComposition.create!(owner: printable, scene_template: worded, text_values: { "headline" => "Core" })

      patch admin_dashboard_board_printable_scene_composition_path(printable, composition), params: { slot_art: page_art(board.id) }
      expect(composition.reload.text_values).to eq("headline" => "Core")

      patch admin_dashboard_board_printable_scene_composition_path(printable, composition),
            params: { slot_art: page_art(board.id), text_values: { "headline" => "" } }
      expect(composition.reload.text_values).to eq({})
    end
  end

  describe "an existing composition" do
    let!(:composition) do
      SceneComposition.create!(owner: printable, scene_template: template, slot_art: page_art(board.id))
    end

    it "updates the art and prunes an upload no slot uses any more" do
      sign_in admin
      blob = composition.attach_slot_upload!(io: StringIO.new(scene_png), filename: "old.png", content_type: "image/png")
      composition.update!(slot_art: { "fridge" => { "source" => "upload", "blob_id" => blob.id } })

      patch admin_dashboard_board_printable_scene_composition_path(printable, composition), params: { slot_art: page_art(other.id) }

      composition.reload
      expect(composition.slot_art["fridge"]["board_id"]).to eq(other.id)
      expect(composition.slot_uploads).to be_empty
      expect(RenderSceneCompositionJob).not_to have_received(:perform_async)
    end

    it "renders the edit page with the render preview area" do
      sign_in admin
      composition.attach_render!(bytes: "jpeg-bytes", digest: composition.current_render_digest)

      get edit_admin_dashboard_board_printable_scene_composition_path(printable, composition)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Rendered scene mockup")
    end

    it "queues a render" do
      sign_in admin
      composition.update_columns(error: "last time failed")

      post render_scene_admin_dashboard_board_printable_scene_composition_path(printable, composition)

      expect(RenderSceneCompositionJob).to have_received(:perform_async).with(composition.id)
      expect(composition.reload.error).to be_nil
    end

    it "can't be reached through a different printable" do
      sign_in admin
      elsewhere = BoardPrintable.create!(board: other, status: "complete", board_ids: [other.id])

      get edit_admin_dashboard_board_printable_scene_composition_path(elsewhere, composition)

      expect(response).to have_http_status(:not_found)
    end

    it "deletes" do
      sign_in admin

      delete admin_dashboard_board_printable_scene_composition_path(printable, composition)

      expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
      expect(SceneComposition.exists?(composition.id)).to be(false)
    end
  end
end
