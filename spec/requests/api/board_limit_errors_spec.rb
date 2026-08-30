# frozen_string_literal: true

require "rails_helper"

# Issue #796 collapsed the two creation caps into one, and gave every limit
# refusal a stable `error_code` so a client has one key to switch on. The
# existing `error` strings are deliberately left alone — several of them are
# human sentences the frontend renders verbatim, and flipping one to a code
# would be a silent break.
RSpec.describe "board-limit 422 contract", type: :request do
  # Free, board_limit 1, already at it.
  let(:user) { create(:user) }
  let!(:existing_board) { create(:board, user: user) }
  let(:headers) { auth_headers(user) }

  def body
    JSON.parse(response.body)
  end

  shared_examples "a board-limit refusal" do
    it "answers 422 with the shared error_code and usage numbers" do
      make_request

      expect(response).to have_http_status(:unprocessable_content)
      expect(body["error_code"]).to eq("board_limit_reached")
      expect(body["limit"]).to eq(1)
      expect(body["count"]).to eq(1)
      expect(body["remaining"]).to eq(0)
      expect(body["required"]).to be >= 1
      expect(body["message"]).to be_present
    end
  end

  describe "POST /api/boards" do
    def make_request
      post "/api/boards", params: { board: { name: "Another" } }, headers: headers
    end

    it_behaves_like "a board-limit refusal"

    it "keeps its human `error` sentence" do
      make_request
      expect(body["error"]).to match(/Maximum number of boards reached \(1\/1\)/)
    end
  end

  describe "POST /api/boards/:id/clone" do
    def make_request
      post "/api/boards/#{existing_board.id}/clone", headers: headers
    end

    it_behaves_like "a board-limit refusal"
  end

  describe "POST /api/boards/create_from_template" do
    def make_request
      post "/api/boards/create_from_template", params: { data: "{}" }, headers: headers
    end

    it_behaves_like "a board-limit refusal"
  end

  describe "POST /api/menus" do
    def make_request
      post "/api/menus", params: { menu: { name: "Dinner" } }, headers: headers
    end

    it_behaves_like "a board-limit refusal"

    # menus_controller carried a drifted copy of the gate: no fresh re-read, no
    # Mailchimp notify, and a message with no counts in it. It shares the
    # concern now, so its body matches the others.
    it "reports the same counts the boards path does" do
      make_request
      expect(body["error"]).to match(/Maximum number of boards reached \(1\/1\)/)
    end
  end

  describe "POST /api/v1/board_builder" do
    let(:communicator) { create(:child_account, user: user) }

    def make_request
      post "/api/v1/board_builder",
           params: { communicator_id: communicator.id, template: "home" }.to_json,
           headers: headers.merge("Content-Type" => "application/json")
    end

    it_behaves_like "a board-limit refusal"

    # This controller's sibling refusals (board_builder_set_exists,
    # unknown_template, build_failed) all put a CODE in `error`, so it matches
    # its own neighbours rather than the sentence convention above.
    it "puts the code in `error` and the prose in `message`" do
      make_request
      expect(body["error"]).to eq("board_limit_reached")
      expect(body["message"]).to match(/needs room for \d+ boards/)
    end

    it "reserves room for the WHOLE set, not one board" do
      make_request
      expect(body["required"]).to eq(Boards::BuilderSetSize.legacy_worst_case)
    end
  end

  describe "POST /api/generated_boards/:token/claim" do
    let(:generated) do
      create(:board, user: create(:user), generated_token: SecureRandom.hex(8))
    end

    def make_request
      post "/api/generated_boards/#{generated.generated_token}/claim", headers: headers
    end

    it_behaves_like "a board-limit refusal"
  end
end
