require "rails_helper"

RSpec.describe "Admin::MissionControl", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:admin) { create(:admin_user) }

  before do
    # The admin layout references application.css which isn't compiled in test
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:javascript_include_tag).and_return("")
  end

  describe "GET /admin/mission_control" do
    before { sign_in admin }

    it "renders the dashboard" do
      get admin_mission_control_path
      expect(response).to have_http_status(:ok)
    end

    it "shows demo user count" do
      create(:user, email: "bhannajohns+test1@gmail.com")
      create(:user, email: "test@speakanyway.com")

      get admin_mission_control_path
      expect(response.body).to include("demo accounts")
    end

    it "renders the Download Leads panel with sync status" do
      create(:download_lead, source: "free_board_landing",
                             mailchimp_status: DownloadLead::MAILCHIMP_FAILED)

      get admin_mission_control_path
      expect(response.body).to include("Download Leads")
      expect(response.body).to include("Mailchimp failed")
      expect(response.body).to include("free_board_landing")
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        get admin_mission_control_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      let(:regular_user) { create(:user) }

      before do
        sign_out admin
        sign_in regular_user
      end

      it "redirects to root" do
        get admin_mission_control_path
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "POST /admin/mission_control/cleanup_demo" do
    before { sign_in admin }

    let!(:demo1) { create(:user, email: "bhannajohns+one@gmail.com") }
    let!(:demo2) { create(:user, email: "bhannajohns+two@gmail.com") }
    let!(:demo3) { create(:user, email: "bhannajohns+three@gmail.com") }
    let!(:demo_with_boards) { create(:user, email: "bhannajohns+boards@gmail.com") }
    let!(:real_user) { create(:user, email: "real@example.com") }

    before do
      3.times { create(:board, user: demo_with_boards) }
      1.times { create(:board, user: demo1) }
    end

    it "deletes demo users keeping top N by board count" do
      expect {
        post cleanup_demo_admin_mission_control_path, params: { keep_count: 1 }
      }.to change(User, :count).by(-3)

      expect(User.exists?(demo_with_boards.id)).to be true
      expect(User.exists?(real_user.id)).to be true
      expect(User.exists?(admin.id)).to be true
    end

    it "respects exclude_ids" do
      expect {
        post cleanup_demo_admin_mission_control_path, params: { keep_count: 1, exclude_ids: demo2.id.to_s }
      }.to change(User, :count).by(-2)

      expect(User.exists?(demo_with_boards.id)).to be true
      expect(User.exists?(demo2.id)).to be true
    end

    it "never deletes admin accounts" do
      admin_demo = create(:admin_user, email: "bhannajohns+admin@gmail.com")

      post cleanup_demo_admin_mission_control_path, params: { keep_count: 0 }

      expect(User.exists?(admin_demo.id)).to be true
    end

    it "never deletes non-demo users" do
      post cleanup_demo_admin_mission_control_path, params: { keep_count: 0 }

      expect(User.exists?(real_user.id)).to be true
    end

    it "redirects with a flash message" do
      post cleanup_demo_admin_mission_control_path, params: { keep_count: 1 }

      expect(response).to redirect_to(admin_mission_control_path)
      follow_redirect!
      expect(response.body).to include("Deleted")
    end

    it "defaults keep_count to 5" do
      post cleanup_demo_admin_mission_control_path

      expect(User.exists?(demo_with_boards.id)).to be true
      expect(User.exists?(demo1.id)).to be true
    end
  end
end
