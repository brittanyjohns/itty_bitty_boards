require "rails_helper"

RSpec.describe AdminBoardBuild do
  it "defaults tags to an empty array and leaves description and audience blank" do
    build = described_class.create!(name: "Playground", columns_count: 2, tile_count: 4)

    expect(build.tags).to eq([])
    expect(build.description).to be_nil
    expect(build.audience).to be_nil
  end

  it "stores tags as an array" do
    build = described_class.create!(
      name: "Playground", columns_count: 2, tile_count: 4,
      tags: %w[playground outdoor play], description: "A board for the playground.",
      audience: "an early communicator",
    )

    expect(build.reload.tags).to eq(%w[playground outdoor play])
    expect(build.description).to eq("A board for the playground.")
    expect(build.audience).to eq("an early communicator")
  end
end
