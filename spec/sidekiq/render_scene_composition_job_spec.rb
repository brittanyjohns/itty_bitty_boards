require "rails_helper"

RSpec.describe RenderSceneCompositionJob do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner) }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }
  let(:composition) { SceneComposition.create!(owner: printable, scene_template: create_scene_template) }
  let(:service) { instance_double(Boards::Printables::RenderSceneComposition) }

  before do
    allow(Boards::Printables::RenderSceneComposition).to receive(:new).and_return(service)
  end

  it "renders the composition" do
    allow(service).to receive(:call)

    described_class.new.perform(composition.id)

    expect(Boards::Printables::RenderSceneComposition).to have_received(:new).with(composition: composition)
    expect(service).to have_received(:call)
  end

  it "does nothing for a composition that no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
    expect(Boards::Printables::RenderSceneComposition).not_to have_received(:new)
  end

  it "records a deterministic failure for the admin and stops retrying" do
    allow(service).to receive(:call).and_raise(Boards::Printables::RenderSceneComposition::Error, "Board #9 isn't part of this printable.")

    expect { described_class.new.perform(composition.id) }.not_to raise_error
    expect(composition.reload.error).to eq("Board #9 isn't part of this printable.")
  end

  it "records a generic message and re-raises anything else, so Sidekiq retries" do
    allow(service).to receive(:call).and_raise(Errno::ECONNREFUSED)

    expect { described_class.new.perform(composition.id) }.to raise_error(Errno::ECONNREFUSED)
    expect(composition.reload.error).to include("retries automatically")
  end

  it "retries twice" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(2)
  end
end
