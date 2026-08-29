require "rails_helper"

RSpec.describe "Admin board builder templates", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:admin) { create(:admin_user) }

  # Required in every admin request spec — the layout calls the asset helpers.
  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  def fringe_template(category: "Animals", name: nil, columns: 2)
    board = create(:board, user: seed_admin, name: name || category, predefined: true, published: true,
                   number_of_columns: columns, large_screen_columns: columns,
                   settings: { Boards::FringeTemplates::TEMPLATE_MARKER => category.downcase,
                               "disable_scroll" => true })
    tile = create(:board_image, board: board, image: create(:image, label: "dog"), label: "dog", position: 0)
    tile.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })
    board.reload
  end

  def plain_admin_board(name: "Dinosaur words")
    board = create(:board, user: seed_admin, name: name, number_of_columns: 2, large_screen_columns: 2)
    tile = create(:board_image, board: board, image: create(:image, label: "rex"), label: "rex", position: 0)
    tile.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })
    board.reload
  end

  describe "authorization" do
    it "redirects a signed-out visitor to sign in" do
      get admin_dashboard_board_builder_templates_path
      expect(response.location).to include("/users/sign_in")
    end

    it "redirects a non-admin away" do
      sign_in create(:user)
      get admin_dashboard_board_builder_templates_path
      expect(response).to redirect_to(root_path)
    end

    it "refuses a non-admin's register" do
      board = plain_admin_board
      sign_in create(:user)

      post register_admin_dashboard_board_builder_templates_path, params: { board_id: board.id, category: "Animals" }

      expect(board.reload.settings[Boards::FringeTemplates::TEMPLATE_MARKER]).to be_nil
    end

    it "refuses a non-admin's re-seed and enqueues nothing" do
      sign_in create(:user)

      expect {
        post reseed_fringe_admin_dashboard_board_builder_templates_path
      }.not_to change(SeedBoardBuilderTemplatesJob.jobs, :size)
    end
  end

  context "as an admin" do
    before { sign_in admin }

    describe "GET index" do
      it "lists fringe templates and vocab sets" do
        fringe_template(category: "Animals")
        get admin_dashboard_board_builder_templates_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Fringe page templates", "Core vocab sets", "Animals")
      end

      it "renders an empty state when nothing is seeded" do
        get admin_dashboard_board_builder_templates_path
        expect(response.body).to include("No fringe templates registered")
      end

      # Board#open_grid_cells saves the board and rewrites every tile's layout, so
      # the obvious way to report grid fullness would mass-write on a GET.
      it "performs no writes" do
        board = fringe_template
        tile_stamps = board.board_images.pluck(:id, :updated_at)

        expect { get admin_dashboard_board_builder_templates_path }
          .not_to change { board.reload.updated_at }
        expect(board.board_images.pluck(:id, :updated_at)).to eq(tile_stamps)
      end

      it "renders a seeded vocab set, naming the SET from the slug not the seed row" do
        create(:board, user: seed_admin, predefined: true, published: true,
               name: "Classroom — Core Words Poster", obf_id: "core-60:core-60",
               settings: { Boards::RobustSets::ROOT_MARKER => true,
                           Boards::RobustSets::SLUG_MARKER => "core-60" })

        get admin_dashboard_board_builder_templates_path

        # display_name_for is keyed on the SLUG, so a renamed seed row cannot
        # rename every user's board — the page must not present it as the name.
        expect(response.body).to include("Core 60")
        expect(response.body).to include("not the set name")
        expect(response.body).to include("Classroom — Core Words Poster")
      end

      it "reports a stray root read-only, with the rake command" do
        create(:board, user: create(:user), name: "A clone", published: true,
               settings: { Boards::RobustSets::ROOT_MARKER => true,
                           Boards::RobustSets::SLUG_MARKER => "core-60" })

        get admin_dashboard_board_builder_templates_path

        expect(response.body).to include("Stray vocab-set roots", "unmark_stray_vocab_roots")
      end

      it "flags a template the planner can never select" do
        fringe_template(category: "Dinosaurs")
        get admin_dashboard_board_builder_templates_path

        expect(response.body).to include("Boards::InterestCategories")
      end
    end

    describe "GET show" do
      it "renders one template with its tiles" do
        board = fringe_template
        get admin_dashboard_board_builder_template_path(board)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Health", "dog")
      end

      it "redirects for a board that is not a template" do
        get admin_dashboard_board_builder_template_path(plain_admin_board)
        expect(response).to redirect_to(admin_dashboard_board_builder_templates_path)
      end
    end

    describe "POST register" do
      it "stamps the marker, disable_scroll, predefined and published" do
        board = plain_admin_board

        post register_admin_dashboard_board_builder_templates_path,
             params: { board_id: board.id, category: "Animals" }

        board.reload
        expect(board.settings[Boards::FringeTemplates::TEMPLATE_MARKER]).to eq("animals")
        expect(board.settings["disable_scroll"]).to be(true)
        expect(board.predefined).to be(true)
        expect(board.published).to be(true)
        expect(Boards::FringeTemplates.find("Animals")).to eq(board)
      end

      it "refuses a board owned by someone other than the seed admin" do
        board = create(:board, user: create(:user), name: "Someone else's")

        post register_admin_dashboard_board_builder_templates_path,
             params: { board_id: board.id, category: "Animals" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(board.reload.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER]).to be_nil
      end

      # source_for_category only ever reaches :prebuilt for a category the planner
      # already produces, so free text would author an unreachable template.
      it "refuses a category the planner does not know" do
        board = plain_admin_board

        post register_admin_dashboard_board_builder_templates_path,
             params: { board_id: board.id, category: "Dinosaurs" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Boards::InterestCategories")
        expect(board.reload.settings.to_h[Boards::FringeTemplates::TEMPLATE_MARKER]).to be_nil
      end

      it "refuses a category that already has a template" do
        fringe_template(category: "Animals", name: "The animals one")
        board = plain_admin_board

        post register_admin_dashboard_board_builder_templates_path,
             params: { board_id: board.id, category: "Animals" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("The animals one")
      end

      # Registering turns on disable_scroll, which locks the board to one screen;
      # a stacked cell there reads as a free cell a build will then spend.
      it "refuses a board with stacked tiles" do
        board = plain_admin_board
        stacked = create(:board_image, board: board, image: create(:image, label: "trike"), label: "trike", position: 1)
        stacked.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })

        post register_admin_dashboard_board_builder_templates_path,
             params: { board_id: board.reload.id, category: "Animals" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("stacked")
      end
    end

    describe "creating from a pasted .obf" do
      def obf_document(overrides = {})
        {
          "format" => "open-board-0.1", "id" => "fringe:animals", "locale" => "en", "name" => "Animals",
          "grid" => { "rows" => 1, "columns" => 2, "order" => [[1, 2]] },
          "buttons" => [{ "id" => 1, "label" => "dog", "part_of_speech" => "noun" },
                        { "id" => 2, "label" => "cat", "part_of_speech" => "noun" }],
          "images" => [], "sounds" => []
        }.merge(overrides)
      end

      it "renders the form" do
        get new_admin_dashboard_board_builder_template_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Authored .obf")
      end

      it "creates the template through the same pass the seeder runs" do
        expect {
          post admin_dashboard_board_builder_templates_path, params: { obf: obf_document.to_json }
        }.to change(Board, :count).by(1)

        board = Boards::FringeTemplates.find("Animals")
        expect(board).to be_present
        expect(board.settings["disable_scroll"]).to be(true)
        expect(board.predefined).to be(true)
        expect(board.board_images.map(&:label)).to contain_exactly("dog", "cat")
      end

      it "keeps what was typed when the JSON does not parse" do
        expect {
          post admin_dashboard_board_builder_templates_path, params: { obf: "{ nope" }
        }.not_to change(Board, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("valid JSON")
        expect(response.body).to include("{ nope")
      end

      it "refuses a document whose name is not a planner category" do
        expect {
          post admin_dashboard_board_builder_templates_path,
               params: { obf: obf_document("name" => "Dinosaurs").to_json }
        }.not_to change(Board, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Boards::InterestCategories")
      end

      # Board.from_obf upserts on (user_id, obf_id), so a document with no id
      # forks a second board on every re-seed.
      it "refuses a document with no id" do
        expect {
          post admin_dashboard_board_builder_templates_path,
               params: { obf: obf_document.except("id").to_json }
        }.not_to change(Board, :count)

        expect(response.body).to include("upserts on it")
      end

      it "refuses a category that already has a template" do
        fringe_template(category: "Animals", name: "The animals one")

        post admin_dashboard_board_builder_templates_path, params: { obf: obf_document.to_json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("The animals one")
      end
    end

    describe "POST unregister" do
      it "clears the marker and predefined, and leaves published alone" do
        board = fringe_template

        post unregister_admin_dashboard_board_builder_template_path(board)

        board.reload
        expect(board.settings[Boards::FringeTemplates::TEMPLATE_MARKER]).to be_nil
        expect(board.predefined).to be(false)
        # Unpublishing is the marketplace-protection raise path and breaks
        # /pb/<slug> for any sheet already printed.
        expect(board.published).to be(true)
      end

      # not_builder_seed keys on the marker and is the ONLY thing keeping an
      # admin-owned, published, predefined board out of the public catalogue.
      it "does not leak the board into the public catalogue" do
        board = fringe_template

        post unregister_admin_dashboard_board_builder_template_path(board)

        expect(Board.public_boards).not_to include(board.reload)
      end

      it "refuses to touch a vocab-set root" do
        root = create(:board, user: seed_admin, predefined: true, published: true, name: "Core 60",
                      settings: { Boards::RobustSets::ROOT_MARKER => true,
                                  Boards::RobustSets::SLUG_MARKER => "core-60" })

        post unregister_admin_dashboard_board_builder_template_path(root)

        expect(root.reload.settings[Boards::RobustSets::ROOT_MARKER]).to be(true)
        expect(flash[:alert]).to include("identity")
      end
    end

    describe "POST repair_layout" do
      it "un-stacks a fringe template inline" do
        board = fringe_template
        stacked = create(:board_image, board: board, image: create(:image, label: "cat"), label: "cat", position: 1)
        stacked.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })

        post repair_layout_admin_dashboard_board_builder_template_path(board.reload)

        expect(response).to redirect_to(admin_dashboard_board_builder_template_path(board))
        expect(stacked.reload.layout["lg"]).not_to eq({ "x" => 0, "y" => 0, "w" => 1, "h" => 1 })
      end

      it "backgrounds a vocab set root" do
        root = create(:board, user: seed_admin, predefined: true, published: true, name: "Core 60",
                      obf_id: "core-60:core-60",
                      settings: { Boards::RobustSets::ROOT_MARKER => true,
                                  Boards::RobustSets::SLUG_MARKER => "core-60" })

        expect {
          post repair_layout_admin_dashboard_board_builder_template_path(root)
        }.to change(RepairBoardBuilderTemplateJob.jobs, :size).by(1)
      end
    end

    describe "GET export" do
      it "sends the authored .obf" do
        board = fringe_template
        board.update_columns(obf_id: "fringe:animals")

        get export_admin_dashboard_board_builder_template_path(board)

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to include("animals.obf")
        expect(JSON.parse(response.body)["id"]).to eq("fringe:animals")
      end
    end

    describe "re-seeding" do
      it "enqueues the fringe re-seed and imports nothing inline" do
        expect {
          post reseed_fringe_admin_dashboard_board_builder_templates_path
        }.to change(SeedBoardBuilderTemplatesJob.jobs, :size).by(1)
          .and not_change(Board, :count)
      end

      it "refuses a fringe source that is not on disk" do
        expect {
          post reseed_fringe_admin_dashboard_board_builder_templates_path, params: { file: "../secrets.obf" }
        }.not_to change(SeedBoardBuilderTemplatesJob.jobs, :size)

        expect(flash[:alert]).to include("No authored fringe source")
      end

      it "enqueues a vocab-set re-seed for an authored slug" do
        skip "no authored vocab sets" if VocabSets.available_slugs.empty?

        expect {
          post reseed_vocab_set_admin_dashboard_board_builder_templates_path,
               params: { slug: VocabSets.available_slugs.first }
        }.to change(SeedBoardBuilderTemplatesJob.jobs, :size).by(1)
      end

      it "refuses an unknown slug and enqueues nothing" do
        expect {
          post reseed_vocab_set_admin_dashboard_board_builder_templates_path, params: { slug: "core-999" }
        }.not_to change(SeedBoardBuilderTemplatesJob.jobs, :size)

        expect(flash[:alert]).to include("No authored source")
      end
    end
  end
end
