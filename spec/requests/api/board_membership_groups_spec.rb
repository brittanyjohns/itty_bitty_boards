require "rails_helper"

# The board read exposes the board's set membership so the frontend can offer a
# board → set-map link (and the builder completion "View the map" CTA). See the
# board-set map handoff.
RSpec.describe "API::Boards board_groups membership", type: :request do
  let(:user) { FactoryBot.create(:user) }

  it "exposes the board's sets with the fields the map link needs" do
    home  = FactoryBot.create(:board, user: user, name: "Home")
    group = FactoryBot.create(:board_group, user: user, builder: true, layout: {})
    group.add_board(home)
    group.update!(root_board_id: home.id)

    get "/api/boards/#{home.id}", headers: auth_headers(user)

    body = JSON.parse(response.body)
    expect(body).to have_key("board_groups")
    bg = body["board_groups"].find { |g| g["id"] == group.id }
    expect(bg).to include(
      "name" => group.name,
      "slug" => group.slug,
      "predefined" => false,
      "builder" => true,
      "root_board_id" => home.id,
    )
  end

  it "returns an empty array for a board that belongs to no set" do
    lone = FactoryBot.create(:board, user: user, name: "Lone")

    get "/api/boards/#{lone.id}", headers: auth_headers(user)

    body = JSON.parse(response.body)
    expect(body["board_groups"]).to eq([])
  end
end
