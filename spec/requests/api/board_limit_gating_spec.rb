require "rails_helper"

# The board cap used to be enforced on boards#create, menus#create,
# generated_boards and the Board Builder — and nowhere else. Three authenticated
# endpoints minted real, countable boards through no gate at all (issue #804),
# and because they left `board_type` NULL those boards were dropped by
# `main_boards` too: counted against the plan, invisible on /boards. That is how
# a Free user reached "Maximum number of boards reached (1/1)" with an empty
# boards page.
#
# One file for all of them because they share a contract: the same 422, the same
# `error_code`, and no Board row written.
RSpec.describe "Board creation limit gating", type: :request do
  # A Free user with their single board already spent — at the cap, not over it.
  let(:free_user) { create(:free_user) }
  let!(:only_board) { create(:board, user: free_user, name: "The One") }
  let(:admin) { create(:user, role: "admin") }

  def limit_refusal!(expected_status: :unprocessable_content)
    expect(response).to have_http_status(expected_status)
    body = JSON.parse(response.body)
    expect(body["error_code"]).to eq("board_limit_reached")
  end

  describe "POST /api/images/:id/create_predictive_board" do
    let(:image) { create(:image, label: "snacks", user: free_user) }
    let(:board_image) { only_board.add_image(image.id) }

    def create_folder!(as:)
      board_image
      post "/api/images/#{image.id}/create_predictive_board",
           params: { board_id: only_board.id, word_list: %w[chips apple], name: "Snacks" },
           headers: auth_headers(as)
    end

    it "refuses a user at their board limit and writes no board" do
      expect { create_folder!(as: free_user) }.not_to change(Board, :count)
      limit_refusal!
    end

    it "does not refuse an admin" do
      admin_image = create(:image, label: "snacks", user: admin)
      admin_board = create(:board, user: admin, name: "Admin hub")
      admin_board.add_image(admin_image.id)

      post "/api/images/#{admin_image.id}/create_predictive_board",
           params: { board_id: admin_board.id, word_list: %w[chips apple], name: "Snacks" },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "PUT /api/board_images/update (update_multiple)" do
    let(:image) { create(:image, label: "apple", user: free_user) }
    let!(:board_image) { create(:board_image, board: only_board, image: image) }

    def bulk_create_board!(as:)
      put "/api/board_images/update",
          params: { board_id: only_board.id, board_image_ids: [board_image.id],
                    payload: { create_new_board: true, new_board_name: "Snacks" } },
          headers: auth_headers(as)
    end

    it "refuses a user at their board limit and writes no board" do
      expect { bulk_create_board!(as: free_user) }.not_to change(Board, :count)
      limit_refusal!
    end

    # The gate sits above the board_images loop on purpose: a refusal must not
    # leave half a bulk edit applied.
    it "leaves the existing tiles untouched when it refuses" do
      before_updated_at = board_image.reload.updated_at

      bulk_create_board!(as: free_user)

      expect(board_image.reload.updated_at).to eq(before_updated_at)
    end

    it "still creates the board for a user with headroom" do
      free_user.update!(settings: (free_user.settings || {}).merge("board_limit" => 10))

      expect { bulk_create_board!(as: free_user) }.to change(Board, :count).by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/scenarios/:id/finalize" do
    let(:scenario) do
      create(:scenario, user: free_user).tap do |s|
        s.update!(questions: { "question_1" => "What happens?" }, answers: {})
      end
    end

    it "refuses a user at their board limit and writes no board" do
      expect {
        post "/api/scenarios/#{scenario.id}/finalize",
             params: { answer: "a snack", question_number: 1 },
             headers: auth_headers(free_user)
      }.not_to change(Board, :count)

      limit_refusal!
    end
  end

  # Menus are the one exemption: a menu the user PUBLISHES is public, so it
  # costs no board slot and a capped user may still add one.
  describe "POST /api/menus" do
    let(:image) do
      Rack::Test::UploadedFile.new(
        Rails.root.join("spec/data/path_images/images/happy.png"), "image/png"
      )
    end

    before { CreditService.grant_plan!(free_user, amount: 100, period_end: 30.days.from_now) }

    it "refuses a PRIVATE menu from a user at their board limit" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", docs: { image: image } } },
             headers: auth_headers(free_user)
      }.not_to change(Board, :count)

      limit_refusal!
    end

    it "allows a PUBLISHED menu from the same capped user, and it stays free" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", published: true, docs: { image: image } } },
             headers: auth_headers(free_user)
      }.to change(Board, :count).by(1)

      expect(response).to have_http_status(:created)
      board = Board.find(JSON.parse(response.body)["boardId"])
      expect(board.published).to be(true)
      expect(board.counts_toward_board_limit?).to be(false)
      expect(User.find(free_user.id).countable_board_count).to eq(1)
    end
  end

  describe "the Mailchimp hit_limit journey" do
    let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:image) { create(:image, label: "snacks", user: free_user) }

    before do
      allow(Rails).to receive(:cache).and_return(memory_cache)
      MailchimpEventJob.clear
    end

    it "fires once when a Free user trips the cap on a newly-gated endpoint" do
      only_board.add_image(image.id)

      expect {
        post "/api/images/#{image.id}/create_predictive_board",
             params: { board_id: only_board.id, word_list: %w[chips], name: "Snacks" },
             headers: auth_headers(free_user)
      }.to change(MailchimpEventJob.jobs, :size).by(1)

      expect(MailchimpEventJob.jobs.last["args"]).to eq(
        [free_user.id, "journey", { "journey_key" => "hit_limit" }],
      )
    end
  end
end
