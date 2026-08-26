require "rails_helper"

RSpec.describe "Admin::BoardPrintableListings (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let!(:board) { create(:board, user: owner, name: "Core Words") }
  let!(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
  end
  let(:listing) { printable.etsy_listings.create! }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    printable.attach_pdf!(filename: "core.pdf", bytes: "pdf", variant: BoardPrintable::VARIANT_FULL)
    allow(Etsy::Client).to receive(:configured?).and_return(true)
  end

  describe "authorization" do
    it "refuses every action to a non-admin" do
      sign_in create(:user)

      post admin_dashboard_board_printable_listings_path(printable)
      expect(response).to redirect_to(root_path)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)
      expect(response).to redirect_to(root_path)

      expect(listing.reload.state).to eq("pending")
    end
  end

  describe "POST create" do
    # Allocating a row must touch nothing external — that ordering is what makes
    # publishing idempotent.
    it "adds a pending row and enqueues nothing" do
      sign_in admin

      expect(PublishBoardPrintableListingJob).not_to receive(:perform_async)

      post admin_dashboard_board_printable_listings_path(printable),
           params: { board_printable_listing: { purpose: "bundle", label: "holiday" } }

      row = printable.etsy_listings.sole
      expect(row).to have_attributes(state: "pending", purpose: "bundle", label: "holiday")
      expect(row.etsy_listing_id).to be_nil
    end

    it "falls back to standalone for a purpose it doesn't know" do
      sign_in admin

      post admin_dashboard_board_printable_listings_path(printable),
           params: { board_printable_listing: { purpose: "wholesale" } }

      expect(printable.etsy_listings.sole.purpose).to eq("standalone")
    end
  end

  describe "POST publish" do
    # THE duplicate-draft test. `update_all` compare-and-sets `state` under the
    # row lock, so only one request can win and only the winner enqueues.
    it "enqueues exactly one job for two back-to-back requests" do
      sign_in admin
      allow(PublishBoardPrintableListingJob).to receive(:perform_async)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)
      post publish_admin_dashboard_board_printable_listing_path(printable, listing)

      expect(PublishBoardPrintableListingJob).to have_received(:perform_async).once
      expect(flash[:alert]).to match(/already being published/)
      expect(listing.reload.state).to eq("publishing")
    end

    it "clears a stale error and saves the generated copy first" do
      sign_in admin
      listing.update_columns(error: "an old failure")
      allow(PublishBoardPrintableListingJob).to receive(:perform_async)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)

      expect(listing.reload.error).to be_nil
      expect(printable.reload.listing_copy["title"]).to be_present
    end

    # Retry is the same operation re-entering the same one-shot claim: nothing
    # was created on Etsy, so there is no duplicate to make.
    it "re-claims a failed row" do
      sign_in admin
      listing.update!(state: "failed", error: "Etsy said no")

      expect(PublishBoardPrintableListingJob).to receive(:perform_async).with(listing.id)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)

      expect(listing.reload.state).to eq("publishing")
    end

    # The inverted rule. This used to be "refuses to create a second listing for
    # the same printable" — carrying two listings is now the point, so what is
    # refused is publishing the same ROW twice.
    it "allows a second listing on the same printable" do
      sign_in admin
      printable.etsy_listings.create!(
        etsy_listing_id: 555, state: "published", published_at: 1.day.ago,
      )
      second = printable.etsy_listings.create!(purpose: "bundle")

      expect(PublishBoardPrintableListingJob).to receive(:perform_async).with(second.id)

      post publish_admin_dashboard_board_printable_listing_path(printable, second)

      expect(flash[:alert]).to be_nil
    end

    it "refuses a row that already has a draft" do
      sign_in admin
      listing.update!(etsy_listing_id: 555, state: "published", published_at: 1.day.ago)

      expect(PublishBoardPrintableListingJob).not_to receive(:perform_async)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)
      expect(flash[:alert]).to match(/already has Etsy draft 555/)
    end

    it "refuses a printable that is still generating" do
      sign_in admin
      printable.update_columns(status: "generating")

      expect(PublishBoardPrintableListingJob).not_to receive(:perform_async)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)
      expect(flash[:alert]).to match(/isn't finished generating/)
    end

    it "refuses when Etsy isn't configured" do
      sign_in admin
      allow(Etsy::Client).to receive(:configured?).and_return(false)

      expect(PublishBoardPrintableListingJob).not_to receive(:perform_async)

      post publish_admin_dashboard_board_printable_listing_path(printable, listing)
      expect(flash[:alert]).to match(/isn't configured/)
    end
  end

  describe "POST supersede" do
    let(:attached) do
      printable.etsy_listings.create!(
        etsy_listing_id: 987, etsy_listing_url: "https://etsy.test/987",
        state: "published", published_at: 2.days.ago,
      )
    end

    # The orphaning fix. Detaching used to NULL the id, so nobody could be told
    # which draft to delete.
    it "keeps the listing id and names it in the notice" do
      sign_in admin

      post supersede_admin_dashboard_board_printable_listing_path(printable, attached)

      expect(attached.reload).to have_attributes(state: "superseded", etsy_listing_id: 987)
      expect(flash[:notice]).to include("987")
    end

    it "keeps the boards it protects frozen" do
      sign_in admin

      post supersede_admin_dashboard_board_printable_listing_path(printable, attached)

      expect(Boards::MarketplaceProtection.new(board).protected?).to be true
    end
  end

  describe "POST replace" do
    let(:attached) do
      printable.etsy_listings.create!(
        etsy_listing_id: 987, state: "published", published_at: 2.days.ago,
        purpose: "bundle", label: "holiday", listing_copy: { "title" => "Holiday Bundle" },
      )
    end

    it "supersedes the old row and adds a pending one carrying its copy" do
      sign_in admin

      post replace_admin_dashboard_board_printable_listing_path(printable, attached)

      expect(attached.reload.state).to eq("superseded")
      replacement = printable.etsy_listings.reload.last
      expect(replacement).to have_attributes(state: "pending", purpose: "bundle", label: "holiday")
      expect(replacement.listing_copy["title"]).to eq("Holiday Bundle")
      expect(replacement.etsy_listing_id).to be_nil
    end

    it "touches Etsy not at all" do
      sign_in admin
      expect(Etsy::Client).not_to receive(:new)

      post replace_admin_dashboard_board_printable_listing_path(printable, attached)
    end
  end

  describe "DELETE destroy" do
    it "removes a row that never reached Etsy" do
      sign_in admin

      delete admin_dashboard_board_printable_listing_path(printable, listing)

      expect(printable.etsy_listings.reload).to be_empty
    end

    # The row is the only record that a draft exists in a real shop — this app
    # implements no delete call, so throwing it away loses the draft.
    it "refuses a row that reached Etsy, even a superseded one" do
      sign_in admin
      reached = printable.etsy_listings.create!(
        etsy_listing_id: 987, state: "superseded",
        published_at: 2.days.ago, superseded_at: 1.day.ago,
      )

      delete admin_dashboard_board_printable_listing_path(printable, reached)

      expect(reached.reload).to be_persisted
      expect(flash[:alert]).to match(/only record of draft 987/)
    end
  end

  describe "POST push_video" do
    let(:attached) do
      printable.etsy_listings.create!(
        etsy_listing_id: 987, state: "published", published_at: 2.days.ago,
      )
    end

    before { printable.attach_video!(bytes: "mp4-bytes", duration: 9.0) }

    it "enqueues the push for that listing" do
      sign_in admin

      expect(PushBoardPrintableListingVideoJob).to receive(:perform_async).with(attached.id)

      post push_video_admin_dashboard_board_printable_listing_path(printable, attached)
    end

    # Etsy's one-video rule is per LISTING, so the same clip going to a
    # printable's standalone AND its bundle is correct — the old printable-wide
    # stamp would have refused the second.
    it "lets a second listing take the same clip" do
      sign_in admin
      attached.mark_video_pushed!
      second = printable.etsy_listings.create!(
        etsy_listing_id: 988, state: "published", published_at: 1.day.ago, purpose: "bundle",
      )

      expect(PushBoardPrintableListingVideoJob).to receive(:perform_async).with(second.id)

      post push_video_admin_dashboard_board_printable_listing_path(printable, second)
    end

    it "refuses a second push at the same listing" do
      sign_in admin
      attached.mark_video_pushed!

      expect(PushBoardPrintableListingVideoJob).not_to receive(:perform_async)

      post push_video_admin_dashboard_board_printable_listing_path(printable, attached)
      expect(flash[:alert]).to match(/already been sent/)
    end

    it "refuses a row with no draft to send to" do
      sign_in admin

      expect(PushBoardPrintableListingVideoJob).not_to receive(:perform_async)

      post push_video_admin_dashboard_board_printable_listing_path(printable, listing)
      expect(flash[:alert]).to match(/isn't attached/)
    end

    # The button is the only caller of #push_video_confirm, and it renders on
    # the WHOLE printable page — a missing helper 500s the admin's view of every
    # listing, not just this one button.
    it "renders the button and its confirm on the printable page" do
      sign_in admin
      attached

      get admin_dashboard_board_printable_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        push_video_admin_dashboard_board_printable_listing_path(printable, attached),
      )
      expect(response.body).to include("Send this video to Etsy listing 987?")
    end

    it "offers no button once this row has taken the clip" do
      sign_in admin
      attached.mark_video_pushed!

      get admin_dashboard_board_printable_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(
        push_video_admin_dashboard_board_printable_listing_path(printable, attached),
      )
    end
  end

  describe "PATCH update" do
    it "stores overrides and drops blanks so they fall back" do
      sign_in admin

      patch admin_dashboard_board_printable_listing_path(printable, listing), params: {
        board_printable_listing: {
          purpose: "bundle", label: "holiday", title: "Core Words Bundle", summary: "",
          price_cents: "1299", tags: "aac, core, bundle", topic_override: "school morning",
          image_variants: [BoardPrintable::IMAGE_HERO], pdf_variants: [BoardPrintable::VARIANT_COLOR],
        },
      }

      expect(listing.reload).to have_attributes(
        purpose: "bundle", label: "holiday", topic_override: "school morning",
      )
      expect(listing.listing_copy["title"]).to eq("Core Words Bundle")
      expect(listing.listing_copy).not_to have_key("summary")
      expect(listing.listing_copy["price_cents"]).to eq(1299)
      expect(listing.listing_copy["tags"]).to eq(%w[aac core bundle])
      expect(listing.selected_image_variants).to eq([BoardPrintable::IMAGE_HERO])
      expect(listing.selected_pdf_variants).to eq([BoardPrintable::VARIANT_COLOR])
    end

    # A typo'd variant would silently drop a slide or a download file from a
    # live listing, which is the kind of failure nobody goes looking for.
    it "refuses a variant it doesn't know" do
      sign_in admin

      patch admin_dashboard_board_printable_listing_path(printable, listing),
            params: { board_printable_listing: { image_variants: ["glossy"] } }

      expect(listing.reload.image_variants).to eq([])
      expect(flash[:alert]).to include("glossy")
    end
  end
end
