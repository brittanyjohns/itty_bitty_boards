require "rails_helper"

RSpec.describe "Admin::SceneTemplates generation and marked uploads", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    GenerateSceneTemplateJob.jobs.clear
    DetectSceneSlotsJob.jobs.clear
  end

  def marked_upload(bytes = magenta_scene_png, content_type: "image/png", filename: "fridge-marked.png")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
  end

  def generate_params(**overrides)
    { scene_generation: { description: "A sunny kitchen with a white fridge", slot_hints: "sheet on the fridge",
                          orientation: "landscape", category: "board" }.merge(overrides) }
  end

  describe "authorization" do
    it "refuses a non-admin every entry point, and enqueues nothing" do
      template = SceneTemplate.create!(name: "x", slug: "x-#{SecureRandom.hex(2)}", generation: { "state" => "queued", "kind" => "upload" })
      sign_in create(:user)

      expect { post generate_admin_dashboard_scene_templates_path, params: generate_params }.not_to change(SceneTemplate, :count)
      expect(response).to redirect_to(root_path)

      post upload_marked_admin_dashboard_scene_templates_path, params: { marked_image: marked_upload }
      expect(response).to redirect_to(root_path)

      get generation_admin_dashboard_scene_template_path(template)
      expect(response).to redirect_to(root_path)

      expect(GenerateSceneTemplateJob.jobs).to be_empty
      expect(DetectSceneSlotsJob.jobs).to be_empty
    end

    it "redirects a signed-out visitor" do
      post generate_admin_dashboard_scene_templates_path, params: generate_params
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET new" do
    it "offers the upload, the marked upload and the paid AI form with a confirm" do
      sign_in admin
      get new_admin_dashboard_scene_template_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Upload magenta-marked PNG", "Generate scene with AI")
      expect(response.body).to include("PAID OpenAI call")
    end
  end

  describe "POST generate" do
    before { sign_in admin }

    it "creates a pending AI template, enqueues the paid job and shows the status page" do
      expect { post generate_admin_dashboard_scene_templates_path, params: generate_params }
        .to change(SceneTemplate, :count).by(1)

      template = SceneTemplate.last
      expect(response).to redirect_to(generation_admin_dashboard_scene_template_path(template))
      expect(response).to have_http_status(:see_other)
      expect(template).to have_attributes(source: "ai", status: "draft", category: "board")
      expect(template.generation).to include("state" => "queued", "kind" => "ai")
      expect(template.generation["request"]).to include("description" => "A sunny kitchen with a white fridge",
                                                        "slot_hints" => "sheet on the fridge", "orientation" => "landscape")
      expect(template.slug).to start_with("a-sunny-kitchen")
      expect(GenerateSceneTemplateJob.jobs.map { |job| job["args"] }).to eq([[template.id]])
    end

    it "refuses a blank description without creating or enqueuing anything" do
      expect { post generate_admin_dashboard_scene_templates_path, params: generate_params(description: " ") }
        .not_to change(SceneTemplate, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Describe the scene to generate.")
      expect(GenerateSceneTemplateJob.jobs).to be_empty
    end
  end

  describe "POST upload_marked" do
    before { sign_in admin }

    it "stores the marked PNG and enqueues detection, not generation" do
      post upload_marked_admin_dashboard_scene_templates_path,
           params: { marked_scene: { name: "", category: "board" }, marked_image: marked_upload }

      template = SceneTemplate.last
      expect(response).to redirect_to(generation_admin_dashboard_scene_template_path(template))
      expect(template.name).to eq("Fridge-marked")
      expect(template.source).to eq("canva")
      expect(template.source_image).to be_attached
      expect(template.base_image).not_to be_attached
      expect(template.generation).to include("state" => "queued", "kind" => "upload")
      expect(DetectSceneSlotsJob.jobs.size).to eq(1)
      expect(GenerateSceneTemplateJob.jobs).to be_empty
    end

    it "refuses a file that isn't really a PNG" do
      require "vips"
      jpeg = Vips::Image.new_from_buffer(magenta_scene_png, "").write_to_buffer(".jpg")

      expect {
        post upload_marked_admin_dashboard_scene_templates_path, params: { marked_image: marked_upload(jpeg) }
      }.not_to change(SceneTemplate, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Save the marked scene as a PNG")
    end

    it "asks for a file when none is sent" do
      post upload_marked_admin_dashboard_scene_templates_path, params: { marked_scene: { name: "x" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Choose the magenta-marked PNG")
    end

    it "runs end to end through the job and opens the calibrator with the detected slots" do
      post upload_marked_admin_dashboard_scene_templates_path, params: { marked_image: marked_upload }
      template = SceneTemplate.last
      DetectSceneSlotsJob.drain

      get generation_admin_dashboard_scene_template_path(template)
      expect(response).to redirect_to(calibrate_admin_dashboard_scene_template_path(template))

      get calibrate_admin_dashboard_scene_template_path(template)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slot1", "slot2")
    end
  end

  describe "GET generation" do
    before { sign_in admin }

    it "refreshes itself while the build runs" do
      template = SceneTemplate.create!(name: "Pending", slug: "pending-#{SecureRandom.hex(2)}",
                                       generation: { "state" => "running", "kind" => "ai",
                                                     "request" => { "description" => "A desk" } })
      get generation_admin_dashboard_scene_template_path(template)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="auto-refresh"', "Generating the scene")
    end

    it "shows the failure note rather than the calibrator when nothing was found" do
      template = SceneTemplate.create!(name: "Failed", slug: "failed-#{SecureRandom.hex(2)}",
                                       generation: { "state" => "failed", "kind" => "ai",
                                                     "error" => Scenes::BuildFromMarkedImage::NO_SLOTS_ERROR,
                                                     "notes" => [Scenes::GenerateTemplate::STAGING_NOTE] })
      get generation_admin_dashboard_scene_template_path(template)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No magenta placeholder surfaces were found", "Staging doesn")
      expect(response.body).not_to include("auto-refresh")
    end
  end

  describe "GET calibrate on a template with no base image yet" do
    it "sends the admin to the status page" do
      sign_in admin
      template = SceneTemplate.create!(name: "Pending", slug: "pending-#{SecureRandom.hex(2)}",
                                       generation: { "state" => "queued", "kind" => "upload" })

      get calibrate_admin_dashboard_scene_template_path(template)
      expect(response).to redirect_to(generation_admin_dashboard_scene_template_path(template))
    end
  end

  describe "the index" do
    it "lists a template that is still building" do
      sign_in admin
      SceneTemplate.create!(name: "Still building", slug: "building-#{SecureRandom.hex(2)}",
                            generation: { "state" => "running", "kind" => "ai" })

      get admin_dashboard_scene_templates_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Still building", "building…")
    end
  end
end
