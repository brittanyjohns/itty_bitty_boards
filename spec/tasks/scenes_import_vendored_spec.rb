require "rails_helper"
require "rake"

RSpec.describe "scenes:import_vendored" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("scenes:import_vendored")
  end

  let(:task) { Rake::Task["scenes:import_vendored"] }
  let(:vendored) { Boards::Printables::TabletScene::SCENES + Boards::Printables::PaperScene::SCENES }

  before { task.reenable }

  def run_task
    expect { task.invoke }.to output(/Created/).to_stdout
  ensure
    task.reenable
  end

  it "creates one calibrated single-slot template per vendored scene" do
    run_task

    templates = SceneTemplate.where(source: "vendored")
    expect(templates.count).to eq(vendored.size)
    expect(templates.map(&:status).uniq).to eq(["calibrated"])

    easel = templates.find_by!(slug: "vendored-classroom-easel")
    expect([easel.width, easel.height]).to eq([1536, 1024])
    expect(easel.slots.size).to eq(1)
    expect(easel.slots.first).to include(
      "key" => "sheet", "kind" => "paper", "orientation" => "landscape",
      "accepts" => %w[page_thumbnail upload], "finish" => "shadow",
    )

    screen = templates.find_by!(slug: "vendored-hands-tablet").slots.first
    expect(screen).to include("key" => "screen", "kind" => "tablet", "accepts" => %w[device_screen upload], "finish" => "glare")
  end

  it "copies each quad verbatim, so the geometry matches the listing mockups" do
    run_task

    vendored.each do |values|
      template = SceneTemplate.find_by!(slug: "vendored-#{values[:slug]}")
      expect(template.slot_objects.first.matrix3d).to eq(Boards::Printables::MockupScene.new(values).matrix3d)
    end
  end

  it "is idempotent" do
    run_task
    ids = SceneTemplate.order(:id).pluck(:id, :calibration_version)

    run_task

    expect(SceneTemplate.order(:id).pluck(:id, :calibration_version)).to eq(ids)
  end

  it "leaves a recalibrated template alone unless FORCE is given" do
    run_task
    template = SceneTemplate.find_by!(slug: "vendored-fridge-magnets")
    template.update!(slots: template.slots.map { |s| s.merge("bleed_px" => 4) })

    run_task
    expect(template.reload.slots.first["bleed_px"]).to eq(4)

    result = Scenes::ImportVendored.call(force: true)
    expect(result.updated).to include("vendored-fridge-magnets")
    expect(template.reload.slots.first["bleed_px"]).to eq(0)
  end
end
