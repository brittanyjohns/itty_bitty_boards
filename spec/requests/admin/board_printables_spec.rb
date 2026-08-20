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

    # The list isn't limited to the curated catalogue or the Board Builder
    # wizard — any admin-owned published board qualifies, predefined or not.
    it "lists a published admin-owned board that was never marked predefined or built via the wizard" do
      sign_in admin
      backup_voice = create(:board, user: default_admin, predefined: false, published: true,
                                    name: "My Backup Voice")

      get admin_dashboard_board_printables_path

      expect(response.body).to include("My Backup Voice")
      expect(response.body).to include("value=\"#{backup_voice.id}\"")
    end

    # Widening past `predefined` must not widen past ownership — a regular
    # user's own published board (e.g. a personal safety board) still isn't
    # the admin's catalogue to offer printables from.
    it "leaves a published board owned by a regular user out of the list" do
      sign_in admin
      create(:board, user: owner, predefined: false, published: true, name: "Owner's Safety Board")

      get admin_dashboard_board_printables_path

      expect(response.body).not_to include("Owner's Safety Board")
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
    # The refresh is a Stimulus controller rather than a
    # `<meta http-equiv="refresh">` on purpose: Turbo Drive carries stale head
    # elements across visits, so the meta version kept reloading whatever page
    # the admin navigated to next. A controller's timer is cleared by
    # disconnect() when the element leaves the page.
    it "shows a pending printable with the scoped auto-refresh controller" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "pending", board_ids: [board.id])

      get admin_dashboard_board_printable_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="auto-refresh"')
      expect(response.body).not_to include('http-equiv="refresh"')
    end

    it "does not auto-refresh a generating printable via a head meta tag" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "generating", board_ids: [board.id])

      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include('data-controller="auto-refresh"')
      expect(response.body).not_to include('http-equiv="refresh"')
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
      expect(response.body).not_to include('data-controller="auto-refresh"')
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
        expect(response.body).to include("Listing copy", "Teachers Pay Teachers", "Add a listing")
        # The link back to the board the printable was built from.
        expect(response.body).to include("Open board ##{board.id}")
      end

      # Nine printables published with identical tag sets before anyone noticed.
      it "warns when the tags collide with another printable's, naming it and the shared tags" do
        sign_in admin
        other_board = create(:board, user: owner, name: "Hair Salon")
        BoardPrintable.create!(
          board: other_board, status: "complete", board_ids: [other_board.id],
          listing_copy: { "tags" => Etsy::ListingCopy.new(printable).build["tags"] },
        )

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).to include("overlap heavily")
        expect(response.body).to include("Hair Salon")
        expect(response.body).to include("communication board")
      end

      it "stays quiet when nothing collides" do
        sign_in admin

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).not_to include("overlap heavily")
      end

      it "links a draft to the seller's listing editor, by numeric id, never by the stored URL string" do
        sign_in admin
        # The stored URL is whatever Etsy's API handed back; the href is built
        # from the bigint id so a string column can never reach an href. It
        # points at the seller editor because a draft has no public page — the
        # public URL Etsy returns is a dead end until someone activates it.
        printable.etsy_listings.create!(
          etsy_listing_id: 987, etsy_listing_url: "https://www.etsy.com/listing/987/core-words",
          state: "published", published_at: 1.day.ago,
        )

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).to include(
          "https://www.etsy.com/your/shops/me/listing-editor/edit/987#media\"",
        )
        expect(response.body).not_to include("core-words\"")
        expect(response.body).not_to include("Create Etsy draft")
      end

      # The record the scalar columns could not keep: a detached listing still
      # names the draft an operator has to go and delete.
      it "shows a card per listing, superseded ones included" do
        sign_in admin
        printable.etsy_listings.create!(
          etsy_listing_id: 111, state: "superseded",
          published_at: 3.days.ago, superseded_at: 2.days.ago,
        )
        printable.etsy_listings.create!(
          etsy_listing_id: 222, state: "published", published_at: 1.day.ago,
          purpose: "bundle", label: "holiday",
        )

        get admin_dashboard_board_printable_path(printable)

        expect(response.body).to include("111")
        expect(response.body).to include("222")
        expect(response.body).to include("holiday")
        expect(response.body).to include("superseded")
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
          tags: "AAC Board, talking communication board, AAC, printable aac", price: "4.50",
        }

        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
        expect(printable.reload.listing_copy).to include(
          "title" => "Core Words",
          # The 27-char tag is dropped here rather than silently by Etsy later,
          # and so is the hand-typed one-word "AAC" — the rule reaches the admin
          # save path, not just generation.
          "tags" => ["aac board", "printable aac"],
          "price_cents" => 450,
        )
      end

      it "does not touch Etsy" do
        sign_in admin
        expect(PublishBoardPrintableListingJob).not_to receive(:perform_async)

        patch update_listing_admin_dashboard_board_printable_path(printable),
              params: { title: "T", description: "D" }
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

    describe "POST regenerate_listing_video" do
      it "enqueues the render job" do
        sign_in admin
        allow(VideoTranscoder).to receive(:available?).and_return(true)

        expect(RenderBoardPrintableListingVideoJob).to receive(:perform_async).with(printable.id)

        post regenerate_listing_video_admin_dashboard_board_printable_path(printable)
        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
      end

      # The job would return immediately, so the page would look like the
      # button did nothing.
      it "says so rather than enqueuing a job that can't work" do
        sign_in admin
        allow(VideoTranscoder).to receive(:available?).and_return(false)

        expect(RenderBoardPrintableListingVideoJob).not_to receive(:perform_async)

        post regenerate_listing_video_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to match(/ffmpeg isn't installed/)
      end

      it "refuses a printable that is still generating" do
        sign_in admin
        printable.update_columns(status: "generating")

        expect(RenderBoardPrintableListingVideoJob).not_to receive(:perform_async)

        post regenerate_listing_video_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to be_present
      end
    end

    describe "POST upload_listing_video" do
      let(:clip) do
        Rack::Test::UploadedFile.new(StringIO.new("mp4-bytes"), "video/mp4", original_filename: "demo.mp4")
      end

      before { allow(VideoTranscoder).to receive(:available?).and_return(false) }

      it "attaches the clip and marks it as the operator's, not a render" do
        sign_in admin

        post upload_listing_video_admin_dashboard_board_printable_path(printable), params: {video: clip}

        printable.reload
        expect(printable.listing_video?).to be true
        expect(printable.listing_video_view[:manual]).to be true
        # Nothing can re-render a hand-made clip, so badging it stale only nags.
        expect(printable.listing_video_current?).to be true
      end

      it "keeps the clip out of the buyer's downloads and the gallery" do
        sign_in admin

        post upload_listing_video_admin_dashboard_board_printable_path(printable), params: {video: clip}

        printable.reload
        expect(printable.files_view.map { |f| f[:filename] }).to all(end_with(".pdf"))
        expect(printable.current_image_files).to be_empty
      end

      it "refuses a file that isn't an mp4" do
        sign_in admin
        png = Rack::Test::UploadedFile.new(StringIO.new("png"), "image/png", original_filename: "nope.png")

        post upload_listing_video_admin_dashboard_board_printable_path(printable), params: {video: png}

        expect(flash[:alert]).to match(/upload an \.mp4/)
        expect(printable.reload.listing_video?).to be false
      end

      # Etsy accepts an out-of-spec clip and only rejects it at activation, so
      # the length has to be checked here or not at all.
      it "refuses a clip outside Etsy's duration window" do
        sign_in admin
        allow(VideoTranscoder).to receive(:available?).and_return(true)
        allow(VideoTranscoder).to receive(:duration).and_return(31.0)

        post upload_listing_video_admin_dashboard_board_printable_path(printable), params: {video: clip}

        expect(flash[:alert]).to match(/between 5 and 15 seconds/)
        expect(printable.reload.listing_video?).to be false
      end

      it "records the probed duration when it can read one" do
        sign_in admin
        allow(VideoTranscoder).to receive(:available?).and_return(true)
        allow(VideoTranscoder).to receive(:duration).and_return(7.5)

        post upload_listing_video_admin_dashboard_board_printable_path(printable), params: {video: clip}

        expect(printable.reload.listing_video_view[:duration]).to eq(7.5)
      end
    end

    describe "editing the topic and regenerating copy" do
      # The topic is create-only no longer: it is the ONLY pool that describes
      # the product, so a listing made without one carries the same 13 tags as
      # every other listing in the shop.
      it "saves the topic alongside the copy" do
        sign_in admin

        patch update_listing_admin_dashboard_board_printable_path(printable), params: {
          title: "T", summary: "S", description: "D", tags: "aac", price: "5.00",
          topic: "hospital stay, doctor visit",
        }

        expect(printable.reload.topic).to eq("hospital stay, doctor visit")
      end

      it "clears the topic when the field is emptied" do
        sign_in admin
        printable.update!(topic: "hospital stay")

        patch update_listing_admin_dashboard_board_printable_path(printable), params: {
          title: "T", summary: "S", description: "D", tags: "aac", price: "5.00", topic: "",
        }

        expect(printable.reload.topic).to be_nil
      end

      # Saving the topic must NOT rewrite the copy: the copy is hand-edited
      # before publishing, and rebuilding it silently would discard that.
      it "leaves the saved copy alone when only the topic changes" do
        sign_in admin

        patch update_listing_admin_dashboard_board_printable_path(printable), params: {
          title: "Hand written title", summary: "S", description: "D", tags: "aac", price: "5.00",
          topic: "hospital stay",
        }

        expect(printable.reload.listing_copy["title"]).to eq("Hand written title")
      end

      it "rebuilds the copy from the topic on regenerate" do
        sign_in admin
        printable.update!(topic: "hospital stay, doctor visit")
        printable.update!(listing_copy: {
          "title" => "stale", "description" => "stale", "tags" => ["aac"], "price_cents" => 500,
        })

        post regenerate_listing_copy_admin_dashboard_board_printable_path(printable)

        tags = printable.reload.listing_copy["tags"]
        expect(printable.listing_copy["title"]).not_to eq("stale")
        expect(tags).to include("hospital stay")
        # The whole point: the topic tags rank straight after the always-on
        # three, so they can't be crowded out by the generic pools.
        expect(tags.index("hospital stay")).to be < tags.index("speech therapy") if tags.include?("speech therapy")
      end

      # The generator emits a constant price, so regenerating would silently
      # reset a price someone chose.
      it "keeps a hand-set price" do
        sign_in admin
        printable.update!(topic: "hospital stay", listing_copy: {
          "title" => "t", "description" => "d", "tags" => [], "price_cents" => 1250,
        })

        post regenerate_listing_copy_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.listing_copy["price_cents"]).to eq(1250)
      end

      it "preserves keys the generator doesn't emit" do
        sign_in admin
        printable.update!(topic: "hospital stay", listing_copy: {
          "title" => "t", "description" => "d", "tags" => [], "tpt_title_override" => "kept",
        })

        post regenerate_listing_copy_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.listing_copy["tpt_title_override"]).to eq("kept")
      end

      # Regenerating is local. A published printable's live listing only changes
      # when the copy is pushed with the printables CLI.
      it "sends nothing to Etsy and leaves the listing attached" do
        sign_in admin
        printable.update!(topic: "hospital stay", etsy_listing_id: 987, etsy_published_at: 1.day.ago)
        allow(Etsy::Client).to receive(:new).and_raise("no Etsy call should be made")

        post regenerate_listing_copy_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.etsy_listing_id).to eq(987)
        expect(flash[:notice]).to match(/[Nn]othing has been sent to Etsy/)
      end

      it "redirects a non-admin away" do
        sign_in create(:user)

        post regenerate_listing_copy_admin_dashboard_board_printable_path(printable)

        expect(response).to redirect_to(root_path)
      end
    end

    describe "POST regenerate" do
      it "re-runs the PDF pipeline on the same record" do
        sign_in admin

        expect(GenerateBoardPrintableJob).to receive(:perform_async).with(printable.id)

        post regenerate_admin_dashboard_board_printable_path(printable)

        expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
        expect(printable.reload.status).to eq("pending")
      end

      it "keeps the listing copy and the Etsy draft — regenerating is about the document" do
        sign_in admin
        allow(GenerateBoardPrintableJob).to receive(:perform_async)
        printable.update!(listing_copy: { "title" => "Reviewed title" }, etsy_listing_id: 987)

        post regenerate_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.listing_copy["title"]).to eq("Reviewed title")
        expect(printable.etsy_listing_id).to eq(987)
      end

      it "clears a previous failure so the status card isn't stale while it re-runs" do
        sign_in admin
        allow(GenerateBoardPrintableJob).to receive(:perform_async)
        printable.update_columns(status: "failed", error_message: "Chrome died")

        post regenerate_admin_dashboard_board_printable_path(printable)

        expect(printable.reload.status).to eq("pending")
        expect(printable.error_message).to be_nil
      end

      it "refuses a printable that is already generating" do
        sign_in admin
        printable.update_columns(status: "generating")

        expect(GenerateBoardPrintableJob).not_to receive(:perform_async)

        post regenerate_admin_dashboard_board_printable_path(printable)
        expect(flash[:alert]).to be_present
      end

      it "refuses a non-admin" do
        sign_in create(:user)

        expect(GenerateBoardPrintableJob).not_to receive(:perform_async)

        post regenerate_admin_dashboard_board_printable_path(printable)
        expect(response).to redirect_to(root_path)
      end
    end

    describe "DELETE destroy" do
      it "deletes the printable and its files" do
        sign_in admin

        expect {
          delete admin_dashboard_board_printable_path(printable)
        }.to change(BoardPrintable, :count).by(-1)

        expect(response).to redirect_to(admin_dashboard_board_printables_path)
        expect(flash[:notice]).to include("Core Words")
      end

      it "leaves the board itself alone" do
        sign_in admin

        delete admin_dashboard_board_printable_path(printable)

        expect(Board.find_by(id: board.id)).to be_present
      end

      it "refuses a non-admin" do
        sign_in create(:user)

        expect {
          delete admin_dashboard_board_printable_path(printable)
        }.not_to change(BoardPrintable, :count)

        expect(response).to redirect_to(root_path)
      end
    end
  end
end
