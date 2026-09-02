# frozen_string_literal: true

require "rails_helper"

# `GET /api/child_boards/:id` is the Speak-app read for a board sitting on a
# communicator's dashboard, reached from the frontend's `/child-boards/:id`
# route. It authenticates a CHILD token, so `current_account` is the
# communicator and there is no `current_user` to serialize for.
#
# Two things it must keep straight, both of which it got wrong before:
# `ChildBoard` has a `board`, not a `child_board`, and the serializer that
# takes a viewing user and a voice lives on `Board` — `ChildBoard`'s
# same-named method takes no arguments at all. The voice is the
# communicator's own, never the shared board row's, exactly as
# `API::Account::ChildBoardsController#show` resolves it.
RSpec.describe "API::ChildBoards#show", type: :request do
  let(:owner) { create(:user, plan_type: "pro") }
  let!(:ava) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                           username: "ava-#{SecureRandom.hex(3)}", passcode: "avapw123")
  end
  let!(:board) { create(:board, user: owner, name: "Core", voice: "polly:kevin") }
  let!(:child_board) { ava.child_boards.create!(board: board, created_by_id: owner.id) }

  before { create(:board_image, board: board, image: create(:image, label: "want")) }

  def child_headers(account)
    { "Authorization" => "Bearer #{account.authentication_token}" }
  end

  it "serializes the attached board for the signed-in communicator" do
    get "/api/child_boards/#{child_board.id}", headers: child_headers(ava)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["id"]).to eq(board.id)
    expect(body["images"].map { |i| i["label"] }).to include("want")
  end

  it "reports the join row and the communicator's read-only permissions" do
    get "/api/child_boards/#{child_board.id}", headers: child_headers(ava)

    body = JSON.parse(response.body)
    expect(body["child_board_id"]).to eq(child_board.id)
    expect(body["can_edit"]).to be false
    expect(body["can_delete"]).to be false
  end

  it "resolves this communicator's voice, not the shared board row's" do
    ava.update!(settings: (ava.settings || {}).merge("voice" => { "name" => "polly:joanna" }))
    allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice) do |_bi, requested, *|
      "https://cdn.test/#{requested}.mp3"
    end

    get "/api/child_boards/#{child_board.id}", headers: child_headers(ava)

    expect(response).to have_http_status(:ok)
    tile = JSON.parse(response.body)["images"].first
    expect(tile["audio_url"]).to eq("https://cdn.test/polly:joanna.mp3")
  end

  it "refuses a request carrying no child token" do
    get "/api/child_boards/#{child_board.id}"

    expect(response).to have_http_status(:unauthorized)
  end
end
