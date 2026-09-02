# frozen_string_literal: true

require "rails_helper"

# Per-communicator voice on a SHARED board.
#
# Assignment attaches a board rather than copying it, so `boards.voice` and
# `board_images.voice` — single-valued columns on a row that can now be on
# several dashboards — stopped being able to answer "what does this
# communicator hear". The read paths pass `child_account.voice` instead, and
# nothing may rewrite the stored voice of a board somebody else is using.
RSpec.describe "Communicator board voice", type: :request do
  let(:owner) { create(:user, plan_type: "pro") }

  def communicator(name)
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                           username: "#{name}-#{SecureRandom.hex(3)}", passcode: "#{name}pw123")
  end

  let(:ava) { communicator("ava") }
  let(:ben) { communicator("ben") }
  let!(:board) { create(:board, user: owner, name: "Core", voice: "polly:kevin") }

  before do
    create(:board_image, board: board, image: create(:image, label: "want"))
    ava.child_boards.create!(board: board, created_by_id: owner.id)
    ben.child_boards.create!(board: board, created_by_id: owner.id)
  end

  describe "ChildAccount#update_audio" do
    it "does not rewrite a board that is on another communicator's dashboard" do
      expect(UpdateBoardsVoiceJob).not_to receive(:perform_async)

      ava.update_audio("polly:joanna")
      expect(board.reload.voice).to eq("polly:kevin")
    end

    it "does not rewrite a board the communicator's owner does not own" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      library = create(:board, user: admin, name: "Library", predefined: true, published: true)
      solo = communicator("solo")
      solo.child_boards.create!(board: library, created_by_id: owner.id)

      expect(UpdateBoardsVoiceJob).not_to receive(:perform_async)
      solo.update_audio("polly:joanna")
      expect(library.reload.voice).not_to eq("polly:joanna")
    end

    # A board on exactly one dashboard, owned by that communicator's owner, is
    # still rewritten — the common single-communicator case, where baking the
    # audio in keeps the board fast.
    it "still rewrites a board only this communicator uses" do
      private_board = create(:board, user: owner, name: "Just Ava's")
      ava.child_boards.create!(board: private_board, created_by_id: owner.id)

      expect(UpdateBoardsVoiceJob).to receive(:perform_async)
        .with([private_board.id], "polly:joanna", anything)

      ava.update_audio("polly:joanna")
    end
  end

  describe "serializing a shared board" do
    before do
      allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice) do |bi, requested, *|
        "https://cdn.test/#{requested}.mp3"
      end
    end

    it "resolves each communicator's own voice off the same board row" do
      ava_tile = board.api_view_with_images(nil, "polly:joanna")[:images].first
      ben_tile = board.api_view_with_images(nil, "polly:matthew")[:images].first

      expect(ava_tile[:audio_url]).to eq("https://cdn.test/polly:joanna.mp3")
      expect(ben_tile[:audio_url]).to eq("https://cdn.test/polly:matthew.mp3")
      # Neither read touched the shared row.
      expect(board.reload.voice).to eq("polly:kevin")
    end

    it "serves the board's stored audio when no voice is asked for" do
      tile = board.api_view_with_images[:images].first
      expect(tile[:audio_url]).not_to eq("https://cdn.test/polly:joanna.mp3")
    end
  end

  describe "GET /api/account/child_boards/:id" do
    it "renders the signed-in communicator's own voice" do
      ava.voice = "polly:joanna"
      child_board = ava.child_boards.find_by(board_id: board.id)
      allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice) do |bi, requested, *|
        "https://cdn.test/#{requested}.mp3"
      end

      get "/api/account/child_boards/#{child_board.id}",
          headers: { "Authorization" => "Bearer #{ava.authentication_token}" }

      expect(response).to have_http_status(:ok)
      tile = JSON.parse(response.body)["images"].first
      expect(tile["audio_url"]).to eq("https://cdn.test/polly:joanna.mp3")
    end
  end
end
