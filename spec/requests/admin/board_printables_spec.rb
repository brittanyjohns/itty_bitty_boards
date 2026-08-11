require "rails_helper"

RSpec.describe "Admin::BoardPrintables (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let(:default_admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let!(:board) { create(:board, user: owner, name: "Core Words") }

  def link(from, to, position: 0)
    create(:board_image, board: from, predictive_board_id: to.id, position: position)
  end

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      printable = BoardPrintable.create!(board: board, status: "pending", board_ids: [board.id])

      get admin_dashboard_board_printables_path
      expect(response).to redirect_to(root_path)

      get admin_dashboard_board_printable_path(printable)
      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_board_printables_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/board_printables" do
    it "lists recent printables" do
      sign_in admin
      BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], created_by: admin)

      get admin_dashboard_board_printables_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Core Words")
      expect(response.body).to include("complete")
    end

    it "lists published public boards without needing a search" do
      sign_in admin
      public_board = create(:board, user: default_admin, predefined: true, published: true, name: "Public Mealtime")

      get admin_dashboard_board_printables_path

      expect(response.body).to include("Public Mealtime")
      expect(response.body).to include("value=\"#{public_board.id}\"")
      # A private board isn't offered up front — it stays behind the search.
      expect(response.body).not_to include("Core Words")
    end

    # Board Builder boards are created published but NOT predefined, so
    # Board.public_boards can't see them — and they are exactly what this page
    # exists to print.
    it "lists published Board Builder boards alongside the catalogue" do
      sign_in admin
      builder_board = create(:board, user: default_admin, predefined: false, published: true,
                                     name: "Builder Playground",
                                     settings: { AdminBoardBuild::BUILDER_SETTING => true })

      get admin_dashboard_board_printables_path

      expect(response.body).to include("Builder Playground")
      expect(response.body).to include("value=\"#{builder_board.id}\"")
    end

    # A printable walks the tree from its root, so a folder page listed as its
    # own row would bury the board it belongs to.
    it "leaves builder child pages and unpublished builder boards out of the list" do
      sign_in admin
      create(:board, user: default_admin, predefined: false, published: true, name: "Builder Food Page",
                     settings: { AdminBoardBuild::BUILDER_SETTING => true, "builder_child" => true })
      create(:board, user: default_admin, predefined: false, published: false, name: "Builder Draft",
                     settings: { AdminBoardBuild::BUILDER_SETTING => true })

      get admin_dashboard_board_printables_path

      expect(response.body).not_to include("Builder Food Page")
      expect(response.body).not_to include("Builder Draft")
    end

    it "leaves unpublished and menu boards out of the public list" do
      sign_in admin
      create(:board, user: default_admin, predefined: true, published: false, name: "Draft Public Board")
      create(:board, user: default_admin, predefined: true, published: true, parent_type: "Menu", name: "Menu Public Board")

      get admin_dashboard_board_printables_path

      expect(response.body).not_to include("Draft Public Board")
      expect(response.body).not_to include("Menu Public Board")
    end

    it "shows each public board's direct subboard count, deduped and ignoring self-links" do
      sign_in admin
      parent = create(:board, user: default_admin, predefined: true, published: true, name: "Public Parent")
      child = create(:board, user: owner, name: "Child One")
      link(parent, child, position: 0)
      link(parent, child, position: 1)
      link(parent, parent, position: 2)

      get admin_dashboard_board_printables_path

      expect(response.body).to include("1 subboard")
      expect(response.body).not_to include("2 subboards")
    end

    it "labels a public board with no subboards" do
      sign_in admin
      create(:board, user: default_admin, predefined: true, published: true, name: "Public Solo")

      get admin_dashboard_board_printables_path

      expect(response.body).to include("None")
    end

    it "shows a created and updated date for each public board" do
      sign_in admin
      created = Time.zone.local(2026, 3, 4, 12, 0)
      updated = Time.zone.local(2026, 5, 6, 12, 0)
      create(:board, user: default_admin, predefined: true, published: true, name: "Public Dated",
             created_at: created, updated_at: updated)

      get admin_dashboard_board_printables_path

      expect(response.body).to include("Mar 4, 2026")
      expect(response.body).to include("May 6, 2026")
    end

    it "links each public board to its public page in a new tab" do
      sign_in admin
      public_board = create(:board, user: default_admin, predefined: true, published: true, name: "Public Mealtime")
      key = Boards::Printables::CollectPages.qr_key_for(public_board)

      get admin_dashboard_board_printables_path

      expect(response.body).to include("/pb/#{key}")
      expect(response.body).to include('target="_blank"')
    end

    describe "sorting the public board list" do
      def public_board_order(body)
        %w[Apple Mango Zebra].sort_by { |name| body.index(">#{name}<") || Float::INFINITY }
      end

      let!(:zebra) do
        create(:board, user: default_admin, predefined: true, published: true, name: "Zebra",
               created_at: 3.days.ago, updated_at: 1.hour.ago)
      end
      let!(:apple) do
        create(:board, user: default_admin, predefined: true, published: true, name: "Apple",
               created_at: 1.day.ago, updated_at: 3.hours.ago)
      end
      let!(:mango) do
        create(:board, user: default_admin, predefined: true, published: true, name: "Mango",
               created_at: 2.days.ago, updated_at: 2.hours.ago)
      end

      before { sign_in admin }

      it "sorts by name ascending by default" do
        get admin_dashboard_board_printables_path

        expect(public_board_order(response.body)).to eq(%w[Apple Mango Zebra])
      end

      it "reverses on dir=desc" do
        get admin_dashboard_board_printables_path(sort: "name", dir: "desc")

        expect(public_board_order(response.body)).to eq(%w[Zebra Mango Apple])
      end

      it "sorts by created date" do
        get admin_dashboard_board_printables_path(sort: "created_at", dir: "asc")

        expect(public_board_order(response.body)).to eq(%w[Zebra Mango Apple])
      end

      it "sorts by updated date" do
        get admin_dashboard_board_printables_path(sort: "updated_at", dir: "asc")

        expect(public_board_order(response.body)).to eq(%w[Apple Mango Zebra])
      end

      it "sorts by subboard count in the database, not just the fetched page" do
        link(mango, create(:board, user: owner, name: "Mango Child"))
        link(zebra, create(:board, user: owner, name: "Zebra Child A"), position: 0)
        link(zebra, create(:board, user: owner, name: "Zebra Child B"), position: 1)

        get admin_dashboard_board_printables_path(sort: "subboards", dir: "desc")

        expect(public_board_order(response.body)).to eq(%w[Zebra Mango Apple])
      end

      it "ignores an unknown sort column rather than interpolating it" do
        get admin_dashboard_board_printables_path(sort: "id; DROP TABLE boards", dir: "asc")

        expect(response).to have_http_status(:ok)
        expect(public_board_order(response.body)).to eq(%w[Apple Mango Zebra])
      end

      it "keeps the picker expanded when a sort is applied" do
        get admin_dashboard_board_printables_path(sort: "created_at")

        expect(response.body).to include("<details open>")
      end

      it "carries the search term through the sort header links" do
        get admin_dashboard_board_printables_path(board_search: "Core", sort: "created_at", dir: "desc")

        expect(response.body).to include("board_search=Core")
        expect(response.body).to include("Core Words")
      end
    end

    it "searches boards by name" do
      sign_in admin

      get admin_dashboard_board_printables_path(board_search: "Core")

      expect(response.body).to include("Core Words")
    end

    it "searches boards by id" do
      sign_in admin

      get admin_dashboard_board_printables_path(board_search: board.id.to_s)

      expect(response.body).to include("Core Words")
    end
  end

  describe "GET /admin/board_printables/:id" do
    it "shows a pending printable with an auto-refresh meta tag" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "pending", board_ids: [board.id])

      get admin_dashboard_board_printable_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('http-equiv="refresh"')
    end

    it "shows download links for a complete printable" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
      allow(printable).to receive(:files_view).and_return([
        { variant: "full", filename: "core-words.pdf", url: "https://cdn.example.com/core-words.pdf", byte_size: 12_345 },
      ])
      allow(BoardPrintable).to receive(:find).and_return(printable)

      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include("https://cdn.example.com/core-words.pdf")
      expect(response.body).not_to include('http-equiv="refresh"')
    end

    it "shows the error message for a failed printable" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "failed", board_ids: [board.id], error_message: "Grover timed out")

      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include("Grover timed out")
    end
  end

  describe "POST /admin/board_printables" do
    it "creates a pending record and enqueues the job" do
      sign_in admin

      expect {
        post admin_dashboard_board_printables_path,
          params: { board_id: board.id, include_subboards: "1", max_boards: "10", topic: "mealtime" }
      }.to change(GenerateBoardPrintableJob.jobs, :size).by(1)

      printable = BoardPrintable.last
      expect(printable.board).to eq(board)
      expect(printable.created_by).to eq(admin)
      expect(printable.include_subboards).to be(true)
      expect(printable.max_boards).to eq(10)
      expect(printable.topic).to eq("mealtime")
      expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
    end

    it "defaults to a single board with the standard cap when no options are given" do
      sign_in admin

      post admin_dashboard_board_printables_path, params: { board_id: board.id }

      printable = BoardPrintable.last
      expect(printable.include_subboards).to be(false)
      expect(printable.max_boards).to eq(BoardPrintable::DEFAULT_MAX_BOARDS)
      expect(printable.board_ids).to eq([board.id])
    end

    it "records the walked tree in BFS order when subboards are included" do
      sign_in admin
      child = create(:board, user: owner)
      link(board, child)

      post admin_dashboard_board_printables_path, params: { board_id: board.id, include_subboards: "1" }

      expect(BoardPrintable.last.board_ids).to eq([board.id, child.id])
    end

    it "clamps an absurd max_boards to the ceiling rather than trusting it" do
      sign_in admin

      post admin_dashboard_board_printables_path, params: { board_id: board.id, max_boards: "100000" }

      expect(BoardPrintable.last.max_boards).to eq(BoardPrintable::MAX_BOARDS_CEILING)
    end

    it "alerts without creating a record when the board doesn't exist" do
      sign_in admin

      expect {
        post admin_dashboard_board_printables_path, params: { board_id: -1 }
      }.not_to change(BoardPrintable, :count)

      expect(response).to redirect_to(admin_dashboard_board_printables_path)
    end

    it "alerts when the tree exceeds max_boards rather than creating a partial record" do
      sign_in admin
      child = create(:board, user: owner)
      link(board, child)

      expect {
        post admin_dashboard_board_printables_path, params: { board_id: board.id, include_subboards: "1", max_boards: "1" }
      }.not_to change(BoardPrintable, :count)

      expect(response).to redirect_to(admin_dashboard_board_printables_path)
      # Exact wording belongs to Boards::Printables::CollectPages, not this controller.
      expect(flash[:alert]).to be_present
    end

    context "when signed in as non-admin" do
      it "redirects to root and does not create a printable" do
        sign_in create(:user)

        expect {
          post admin_dashboard_board_printables_path, params: { board_id: board.id }
        }.not_to change(BoardPrintable, :count)

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "listing and publishing" do
    let!(:printable) do
      BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
    end

    before do
      printable.attach_pdf!(filename: "core.pdf", bytes: "pdf", variant: BoardPrintable::VARIANT_FULL)
    end

    describe "authorization" do
      it "refuses every member action to a non-admin" do
        sign_in create(:user)

        patch update_listing_admin_dashboard_board_printable_path(printable), params: { title: "x" }
        expect(response).to redirect_to(root_path)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)
        expect(response).to redirect_to(root_path)

        post regenerate_listing_images_admin_dashboard_board_printable_path(printable)
        expect(response).to redirect_to(root_path)

        expect(printable.reload.listing_copy).to eq({})
      end
    end

    describe "GET show" do
      it "renders the generated listing copy and the paste blocks" do
        sign_in admin
        allow(Etsy::Client).to receive(:configured?).and_return(true)

        get admin_dashboard_board_printable_path(printable)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Listing copy", "Teachers Pay Teachers", "Create Etsy draft")
        # The link back to the board the printable was built from.
        expect(response.body).to include("Open board ##{board.id}")
      end

      it "links a draft to the seller's listing editor, by numeric id, never by the stored URL string" do
        sign_in admin
        # The stored URL is whatever Etsy's API handed back; the href is built
        # from the bigint id so a string column can never reach an href. It
        # points at the seller editor because a draft has no public page — the
        # public URL Etsy returns is a dead end until someone activates it.
        printable.update!(etsy_listing_id: 987, etsy_listing_url: "https://www.etsy.com/listing/987/core-words")

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).to include(
          "https://www.etsy.com/your/shops/me/listing-editor/edit/987#media\"",
        )
        expect(response.body).not_to include("core-words\"")
        expect(response.body).not_to include("Create Etsy draft")
      end

      it "says Etsy is unconfigured instead of offering a button that would fail" do
        sign_in admin
        allow(Etsy::Client).to receive(:configured?).and_return(false)

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).to include("Etsy isn't configured")
        expect(response.body).not_to include("Create Etsy draft")
      end
    end

    describe "PATCH update_listing" do
      it "saves the copy and normalizes the tags to what Etsy will accept" do
        sign_in admin

        patch update_listing_admin_dashboard_board_printable_path(printable), params: {
          title: "Core Words", summary: "S", description: "D",
          tags: "AAC, talking communication board, printable", price: "4.50",
        }

        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
        expect(printable.reload.listing_copy).to include(
          "title" => "Core Words",
          # The 27-char tag is dropped here rather than silently by Etsy later.
          "tags" => ["aac", "printable"],
          "price_cents" => 450,
        )
      end

      it "does not touch Etsy" do
        sign_in admin
        expect(PublishBoardPrintableToEtsyJob).not_to receive(:perform_async)

        patch update_listing_admin_dashboard_board_printable_path(printable),
              params: { title: "T", description: "D" }
      end
    end

    describe "POST publish_to_etsy" do
      before { allow(Etsy::Client).to receive(:configured?).and_return(true) }

      it "enqueues the publish job and clears a stale error" do
        sign_in admin
        printable.update_columns(etsy_error: "an old failure")

        expect(PublishBoardPrintableToEtsyJob).to receive(:perform_async).with(printable.id)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)

        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
        expect(printable.reload.etsy_error).to be_nil
      end

      it "saves the generated copy first, so the draft matches what the page showed" do
        sign_in admin
        allow(PublishBoardPrintableToEtsyJob).to receive(:perform_async)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.listing_copy["title"]).to be_present
      end

      it "refuses a printable that is still generating" do
        sign_in admin
        printable.update_columns(status: "generating")

        expect(PublishBoardPrintableToEtsyJob).not_to receive(:perform_async)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to match(/isn't finished generating/)
      end

      it "refuses to create a second listing for the same printable" do
        sign_in admin
        printable.update!(etsy_listing_id: 555)

        expect(PublishBoardPrintableToEtsyJob).not_to receive(:perform_async)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to match(/Already on Etsy as listing 555/)
      end

      it "refuses when Etsy isn't configured" do
        sign_in admin
        allow(Etsy::Client).to receive(:configured?).and_return(false)

        expect(PublishBoardPrintableToEtsyJob).not_to receive(:perform_async)

        post publish_to_etsy_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to match(/isn't configured/)
      end
    end

    describe "POST regenerate_listing_images" do
      it "enqueues the render job" do
        sign_in admin

        expect(RenderBoardPrintableListingImagesJob).to receive(:perform_async).with(printable.id)

        post regenerate_listing_images_admin_dashboard_board_printable_path(printable)
        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
      end

      it "refuses a printable that is still generating" do
        sign_in admin
        printable.update_columns(status: "generating")

        expect(RenderBoardPrintableListingImagesJob).not_to receive(:perform_async)

        post regenerate_listing_images_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to be_present
      end
    end
  end
end
