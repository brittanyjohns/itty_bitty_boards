require "rails_helper"

RSpec.describe "Admin::SceneTemplates (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin away from the library and the calibrator" do
      template = create_scene_template
      sign_in create(:user)

      get admin_dashboard_scene_templates_path
      expect(response).to redirect_to(root_path)

      get calibrate_admin_dashboard_scene_template_path(template)
      expect(response).to redirect_to(root_path)

      patch save_calibration_admin_dashboard_scene_template_path(template), params: { slots_json: "[]" }
      expect(response).to redirect_to(root_path)
      expect(template.reload.slots).to be_present
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_scene_templates_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET index" do
    it "lists active templates and hides archived ones by default" do
      sign_in admin
      create_scene_template(name: "Fridge pair")
      create_scene_template(name: "Old easel", status: "archived")

      get admin_dashboard_scene_templates_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fridge pair")
      expect(response.body).not_to include("Old easel")

      get admin_dashboard_scene_templates_path(status: "archived")
      expect(response.body).to include("Old easel")
    end
  end

  describe "POST create" do
    it "uploads a base image, reads its size and opens the calibrator" do
      sign_in admin

      post admin_dashboard_scene_templates_path, params: {
        scene_template: { name: "Fridge pair", slug: "fridge-pair", category: "board", source: "canva" },
        base_image: uploaded_scene_png(640, 480),
      }

      template = SceneTemplate.find_by!(slug: "fridge-pair")
      expect(response).to redirect_to(calibrate_admin_dashboard_scene_template_path(template))
      expect([template.width, template.height]).to eq([640, 480])
      expect(template).to be_draft
      expect(template.base_image).to be_attached
    end

    it "refuses a file that isn't an allowed image" do
      sign_in admin

      post admin_dashboard_scene_templates_path, params: {
        scene_template: { name: "Bad", slug: "bad" },
        base_image: Rack::Test::UploadedFile.new(StringIO.new("<svg/>"), "image/svg+xml", original_filename: "x.svg"),
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("image/svg+xml")
      expect(SceneTemplate.exists?(slug: "bad")).to be(false)
    end
  end

  describe "calibration" do
    let(:template) { create_scene_template(status: "draft", slots: []) }

    it "renders the calibrator with the template's slots and size" do
      sign_in admin

      get calibrate_admin_dashboard_scene_template_path(template)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="scene-calibrator"')
      expect(response.body).to include('data-scene-calibrator-width-value="400"')
    end

    it "saves slots, marks the template calibrated and bumps the version" do
      sign_in admin
      slots = [scene_slot(key: "fridge"), scene_slot(key: "easel", quad: [[200, 40], [380, 40], [380, 200], [200, 200]])]

      patch save_calibration_admin_dashboard_scene_template_path(template),
            params: { slots_json: slots.to_json, mark_calibrated: "1" }

      expect(response).to redirect_to(calibrate_admin_dashboard_scene_template_path(template))
      template.reload
      expect(template.slots.map { |s| s["key"] }).to eq(%w[fridge easel])
      expect(template).to be_calibrated
      expect(template.calibration_version).to eq(1)
    end

    it "refuses an invalid quad and keeps the saved slots" do
      sign_in admin
      bad = [scene_slot(quad: [[40, 40], [900, 40], [900, 200], [40, 200]])]

      patch save_calibration_admin_dashboard_scene_template_path(template), params: { slots_json: bad.to_json }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("inside the 400x300")
      expect(template.reload.slots).to eq([])
    end

    it "refuses JSON it can't read" do
      sign_in admin

      patch save_calibration_admin_dashboard_scene_template_path(template), params: { slots_json: "{not json" }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH update" do
    it "renames and adds a front layer" do
      sign_in admin
      template = create_scene_template

      patch admin_dashboard_scene_template_path(template), params: {
        scene_template: { name: "Renamed" },
        front_layer: uploaded_scene_png(400, 300, filename: "front.png"),
      }

      expect(response).to redirect_to(edit_admin_dashboard_scene_template_path(template))
      template.reload
      expect(template.name).to eq("Renamed")
      expect(template.front_layer).to be_attached
      expect(template.calibration_version).to eq(1)
    end

    it "removes a front layer" do
      sign_in admin
      template = create_scene_template(front_layer: true)

      patch admin_dashboard_scene_template_path(template), params: { scene_template: { name: template.name }, remove_front_layer: "1" }

      expect(template.reload.front_layer).not_to be_attached
    end
  end

  describe "retiring" do
    let(:board) { create(:board, user: create(:user)) }
    let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }

    it "deletes a template nothing uses" do
      sign_in admin
      template = create_scene_template

      delete admin_dashboard_scene_template_path(template)

      expect(SceneTemplate.exists?(template.id)).to be(false)
    end

    it "archives instead of deleting a template in use" do
      sign_in admin
      template = create_scene_template
      SceneComposition.create!(owner: printable, scene_template: template)

      delete admin_dashboard_scene_template_path(template)

      expect(template.reload).to be_archived
      follow_redirect!
      expect(response.body).to include("archived instead of deleted")
    end

    it "archives on request" do
      sign_in admin
      template = create_scene_template

      post archive_admin_dashboard_scene_template_path(template)

      expect(template.reload).to be_archived
    end
  end
end
