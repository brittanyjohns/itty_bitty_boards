require "rails_helper"

RSpec.describe "Scene template build jobs" do
  def pending_template(kind:)
    SceneTemplate.create!(
      name: "Scene", slug: "scene-#{SecureRandom.hex(3)}", category: "board",
      source: kind == SceneTemplate::GENERATION_KIND_AI ? "ai" : "canva", status: SceneTemplate::STATUS_DRAFT,
      generation: { "state" => SceneTemplate::GENERATION_QUEUED, "kind" => kind,
                    "request" => { "description" => "A kitchen", "orientation" => "landscape" } },
    )
  end

  describe GenerateSceneTemplateJob do
    it "never retries: every attempt is a paid call" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(0)
    end

    it "claims the template once, so a duplicate enqueue can't pay twice" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_AI)
      service = instance_double(Scenes::GenerateTemplate, call: template)
      allow(Scenes::GenerateTemplate).to receive(:new).and_return(service)

      described_class.new.perform(template.id)
      described_class.new.perform(template.id)

      expect(service).to have_received(:call).once
      expect(template.reload.generation_state).to eq("running")
    end

    it "records a failure on the template and re-raises" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_AI)
      allow(Scenes::GenerateTemplate).to receive(:new).and_raise(Faraday::ServerError, "upstream")

      expect { described_class.new.perform(template.id) }.to raise_error(Faraday::ServerError)

      expect(template.reload.generation_state).to eq("failed")
      expect(template.generation["error"]).to include("isn't retried")
    end

    it "is enqueued after commit by the template" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_AI)
      expect { template.enqueue_generation! }.to change(described_class.jobs, :size).by(1)
    end
  end

  describe DetectSceneSlotsJob do
    it "detects the slots of the uploaded marked scene" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_UPLOAD)
      template.source_image.attach(io: StringIO.new(magenta_scene_png), filename: "marked.png", content_type: "image/png")
      expect(OpenAI::Client).not_to receive(:new)

      described_class.new.perform(template.id)
      template.reload

      expect(template.generation_state).to eq("complete")
      expect(template.slots.size).to eq(2)
      expect(template.front_layer).to be_attached
    end

    it "fails clearly when the marked scene is missing" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_UPLOAD)

      expect { described_class.new.perform(template.id) }.to raise_error(ArgumentError)
      expect(template.reload.generation["error"]).to include("PNG")
    end

    it "is enqueued for an upload" do
      template = pending_template(kind: SceneTemplate::GENERATION_KIND_UPLOAD)
      expect { template.enqueue_generation! }.to change(described_class.jobs, :size).by(1)
    end
  end
end
