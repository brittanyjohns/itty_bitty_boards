require "rails_helper"

# The admin half of marketplace protection: the banner that explains why a
# board is frozen, and the one deliberate way to release it.
RSpec.describe "Admin::BoardPrintables marketplace protection", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:root) { create(:board, user: admin, name: "Daily Routines", published: true) }
  let(:page) { create(:board, user: admin, name: "Snack Time", published: true) }

  let(:printable) do
    BoardPrintable.create!(
      board: root,
      status: "complete",
      board_ids: [root.id, page.id],
      etsy_listing_id: 1234567890,
    )
  end

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    sign_in admin
  end

  describe "the show page" do
    it "explains that the printable's boards are frozen" do
      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include("Protected")
      expect(response.body).to include("2 boards")
      expect(response.body).to include("renamed or unpublished")
      expect(response.body).to include("Release protection")
    end

    it "says nothing when the printable never reached Etsy" do
      unpublished = BoardPrintable.create!(board: root, status: "complete", board_ids: [root.id])

      get admin_dashboard_board_printable_path(unpublished)

      expect(response.body).not_to include("Release protection")
    end
  end

  describe "POST waive_protection" do
    it "releases the boards and records who did it" do
      post waive_protection_admin_dashboard_board_printable_path(printable)

      expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
      expect(printable.reload.protection_waived_at).to be_present
      expect(printable.protection_waived_by).to eq(admin)
      expect(root.reload.marketplace_protected?).to be false
    end

    # The listing pointer is deliberately untouched — the record still has to
    # say which Etsy draft this was.
    it "keeps the Etsy listing id" do
      post waive_protection_admin_dashboard_board_printable_path(printable)

      expect(printable.reload.etsy_listing_id).to eq(1234567890)
    end

    it "lets the board be deleted afterwards" do
      post waive_protection_admin_dashboard_board_printable_path(printable)

      expect { page.reload.destroy! }.not_to raise_error
    end

    it "refuses when the printable was never published" do
      unpublished = BoardPrintable.create!(board: root, status: "complete", board_ids: [root.id])

      post waive_protection_admin_dashboard_board_printable_path(unpublished)

      expect(flash[:alert]).to include("isn't protecting anything")
      expect(unpublished.reload.protection_waived_at).to be_nil
    end

    it "is a no-op when protection was already released" do
      printable.waive_protection!(user: admin)
      first_stamp = printable.reload.protection_waived_at

      post waive_protection_admin_dashboard_board_printable_path(printable)

      expect(flash[:alert]).to include("already released")
      expect(printable.reload.protection_waived_at).to eq(first_stamp)
    end

    it "is closed to non-admins" do
      sign_in create(:user)

      post waive_protection_admin_dashboard_board_printable_path(printable)

      expect(response).to redirect_to(root_path)
      expect(printable.reload.protection_waived_at).to be_nil
    end
  end

  describe "the board picker" do
    it "badges a board that's already sold as a printable" do
      printable

      get admin_dashboard_board_printables_path(board_search: "Snack Time")

      expect(response.body).to include("Protected")
    end
  end
end
