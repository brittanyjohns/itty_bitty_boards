require "rails_helper"

RSpec.describe "API::Menus", type: :request do
  let(:user) { create(:user) }

  describe "POST /api/menus" do
    let(:image) do
      Rack::Test::UploadedFile.new(
        Rails.root.join("spec/data/path_images/images/happy.png"), "image/png"
      )
    end

    # Menu creation is credit-gated: flat menu_create fee + the per-image
    # budget (default 10 images x 1 credit). Give the user plenty so these
    # specs exercise menu creation, not the credit gate itself.
    before do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
    end

    it "requires authentication" do
      post "/api/menus", params: { menu: { name: "Lunch" } }
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a menu board from a name and image with no extracted text" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", docs: { image: image } } },
             headers: auth_headers(user)
      }.to change(Menu, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Joe's Diner")
      expect(body["boardId"]).to be_present
    end

    it "saves the menu board's display image full size, not the small tile variant" do
      post "/api/menus",
           params: { menu: { name: "Joe's Diner", docs: { image: image } } },
           headers: auth_headers(user)

      board = Menu.last.boards.last
      doc = Menu.last.docs.last
      expect(board.display_image_url).to be_present
      expect(board.display_image_url).not_to eq(doc.tile_url)
    end

    it "enqueues the vision extraction job" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", docs: { image: image } } },
             headers: auth_headers(user)
      }.to change(EnhanceImageDescriptionJob.jobs, :size).by(1)
    end

    describe "image budget (token_limit)" do
      def create_menu(token_limit)
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", token_limit: token_limit, docs: { image: image } } },
             headers: auth_headers(user)
      end

      it "charges the flat fee plus the picked budget and stashes the reservation" do
        expect { create_menu(4) }
          .to change { user.reload.plan_credits_balance }.by(-9) # 5 flat + 4 x 1

        expect(response).to have_http_status(:created)
        menu = Menu.last
        expect(menu.token_limit).to eq(4)
        reservation = menu.boards.last.settings["menu_credit"]
        expect(reservation["reserved"]).to eq(4)
        expect(reservation["per_image"]).to eq(1)
        expect(CreditTransaction.find(reservation["txn_id"]).amount).to eq(-9)
      end

      it "clamps the budget to MENU_MAX_IMAGES" do
        expect { create_menu(999) }
          .to change { user.reload.plan_credits_balance }.by(-35) # 5 + 30 x 1
        expect(Menu.last.token_limit).to eq(30)
      end

      it "falls back to the default budget on a garbage value" do
        expect { create_menu("nonsense") }
          .to change { user.reload.plan_credits_balance }.by(-15) # 5 + 10 x 1
        expect(Menu.last.token_limit).to eq(10)
      end

      it "returns 402 when the balance cannot cover the budget" do
        user.update!(plan_credits_balance: 8, topup_credits_balance: 0)

        expect { create_menu(30) }.not_to change(Menu, :count)

        expect(response).to have_http_status(:payment_required)
        expect(JSON.parse(response.body)["error"]).to eq("insufficient_credits")
      end
    end
  end

  describe "POST /api/menus/:id/rerun" do
    let(:menu) { FactoryBot.create(:menu, user: user, token_limit: 10) }
    let!(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu",
                                parent_type: "Menu", parent_id: menu.id)
    end

    before do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      allow_any_instance_of(Menu).to receive(:enhance_image_description)
        .and_return({ "menu_items" => [{ "name" => "cheeseburger" }] })
    end

    it "rejects a user who does not own the menu" do
      stranger = FactoryBot.create(:user)
      CreditService.grant_plan!(stranger, amount: 100, period_end: 30.days.from_now)

      post "/api/menus/#{menu.id}/rerun", headers: auth_headers(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "charges a fresh build cost and stashes the reservation on the board" do
      expect {
        post "/api/menus/#{menu.id}/rerun", params: { token_limit: 3 }, headers: auth_headers(user)
      }.to change { user.reload.plan_credits_balance }.by(-8) # 5 + 3 x 1

      expect(response).to have_http_status(:ok)
      expect(menu.reload.token_limit).to eq(3)
      expect(board.reload.settings["menu_credit"]["reserved"]).to eq(3)
    end

    it "refunds the whole spend when extraction produces nothing" do
      allow_any_instance_of(Menu).to receive(:enhance_image_description).and_return(nil)

      expect {
        post "/api/menus/#{menu.id}/rerun", params: { token_limit: 3 }, headers: auth_headers(user)
      }.not_to change { user.reload.plan_credits_balance }
    end
  end
end
