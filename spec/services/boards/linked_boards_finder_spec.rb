require "rails_helper"

RSpec.describe Boards::LinkedBoardsFinder do
  let(:user) { FactoryBot.create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  it "returns the root plus every board reachable via folder links" do
    home  = FactoryBot.create(:board, user: user, name: "Home")
    food  = FactoryBot.create(:board, user: user, name: "Food")
    fruit = FactoryBot.create(:board, user: user, name: "Fruit")
    orphan = FactoryBot.create(:board, user: user, name: "Orphan")

    add_tile(home, label: "Food", links_to: food)
    add_tile(food, label: "Fruit", links_to: fruit)
    add_tile(orphan, label: "lonely")

    result = described_class.new(home).call
    expect(result.map(&:id)).to contain_exactly(home.id, food.id, fruit.id)
  end

  it "does not loop forever on a cycle" do
    a = FactoryBot.create(:board, user: user, name: "A")
    b = FactoryBot.create(:board, user: user, name: "B")
    add_tile(a, label: "to b", links_to: b)
    add_tile(b, label: "to a", links_to: a)

    result = described_class.new(a).call
    expect(result.map(&:id)).to contain_exactly(a.id, b.id)
  end

  it "returns just the root when it links to nothing" do
    solo = FactoryBot.create(:board, user: user, name: "Solo")
    add_tile(solo, label: "word")

    result = described_class.new(solo).call
    expect(result.map(&:id)).to contain_exactly(solo.id)
  end
end
