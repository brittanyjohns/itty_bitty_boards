require "rails_helper"

# The core floor belongs at the APPROVAL step, not after it: a word added
# between "Generate words" and "Create board" is a tile that appears on the
# board having never been shown to anyone, which is the same complaint as the
# two extra tiles a 24-word approval used to produce.
#
# Its scope is the same as BOARD_COVERAGE_RULES' — a whole board being drafted,
# never a top-up of a board that already exists. Forcing `yes` and `help` into
# ten more words for a fringe page called "Places" is the bug
# incremental_word_rules exists to stop, one layer down.
RSpec.describe "API::Boards word core floor", type: :request do
  let(:user) { create(:user) }
  let(:suggest) { :get_word_suggestions_from_default_prompt }

  before do
    allow_any_instance_of(API::BoardsController).to receive(:check_credits!).and_return(true)
  end

  context "when a whole new board is being drafted (no board_id)" do
    it "adds the missing core words to the list the user is about to approve" do
      allow_any_instance_of(Board).to receive(suggest)
        .and_return(["hello", "I feel happy", "no", "stop", "all done", "different"])

      get "/api/boards/words",
          params: { name: "Morning Circle Time", num_of_words: 24 },
          headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("yes")
    end

    it "leaves a list that already covers the floor untouched" do
      words = ["yes", "no", "more", "help", "stop", "I want"]
      allow_any_instance_of(Board).to receive(suggest).and_return(words)

      get "/api/boards/words",
          params: { name: "Core", num_of_words: 24 },
          headers: auth_headers(user)

      expect(JSON.parse(response.body)).to eq(words)
    end
  end

  context "when words are being added to a board that already exists" do
    let!(:places) { create(:board, user: user, name: "Places") }

    it "adds nothing — a fringe page names things on purpose" do
      words = %w[park school library beach museum]
      allow_any_instance_of(Board).to receive(suggest).and_return(words)

      get "/api/boards/words",
          params: { board_id: places.id, name: "Places", num_of_words: 5 },
          headers: auth_headers(user)

      expect(JSON.parse(response.body)).to eq(words)
    end
  end
end
