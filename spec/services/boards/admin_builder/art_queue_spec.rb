require "rails_helper"

RSpec.describe Boards::AdminBuilder::ArtQueue do
  let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:board) { Board.create!(name: "Playground", slug: "playground-art", user: seed_admin) }

  before { GenerateImagesJob.jobs.clear }

  def image(label, prompt: nil)
    Image.create!(label: label, user: seed_admin, image_prompt: prompt)
  end

  it "queues in batches of three" do
    ids = 7.times.map { |n| image("word#{n}").id }

    expect(described_class.call(board: board, image_ids: ids)).to eq(7)
    expect(GenerateImagesJob.jobs.size).to eq(3)
    expect(GenerateImagesJob.jobs.map { |job| job["args"].first.size }).to eq([3, 3, 1])
    expect(GenerateImagesJob.jobs.first["args"][1]).to eq(board.id)
  end

  # These images already carry a library doc, so the generated one has to be
  # promoted over it or the build shows the symbol the admin just rejected.
  it "tells the job to replace the current doc when regenerating over existing art" do
    id = image("swing").id

    described_class.call(board: board, image_ids: [id], replace_current: true)

    expect(GenerateImagesJob.jobs.first["args"][2]).to eq("replace_current" => true)
  end

  it "sends no replace option for ordinary missing-art generation" do
    id = image("swing").id

    described_class.call(board: board, image_ids: [id])

    expect(GenerateImagesJob.jobs.first["args"][2]).to eq({})
  end

  it "does nothing when there is nothing to queue" do
    expect(described_class.call(board: board, image_ids: [])).to eq(0)
    expect(GenerateImagesJob.jobs).to be_empty
  end

  it "deduplicates ids" do
    id = image("swing").id

    expect(described_class.call(board: board, image_ids: [id, id])).to eq(1)
  end

  # The topic is what keeps "swing" on a playground board from coming back as a
  # mood swing.
  it "seeds a blank prompt with the label in the board's context" do
    swing = image("swing")

    described_class.call(board: board, image_ids: [swing.id], topic: "the playground")

    expect(swing.reload.image_prompt).to eq("swing in the context of the playground")
  end

  it "seeds a blank prompt with the bare label when there is no topic" do
    swing = image("swing")

    described_class.call(board: board, image_ids: [swing.id])

    expect(swing.reload.image_prompt).to eq("swing")
  end

  # Images::PromptBuilder composes the house style envelope at generation time;
  # an existing prompt is intent someone chose and must not be rewritten.
  it "leaves an existing prompt alone" do
    swing = image("swing", prompt: "a hand-written intent")

    described_class.call(board: board, image_ids: [swing.id], topic: "the playground")

    expect(swing.reload.image_prompt).to eq("a hand-written intent")
  end
end
