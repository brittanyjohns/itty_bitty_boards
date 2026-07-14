require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  include Devise::Test::IntegrationHelpers

  let_it_be(:admin) { create(:admin_user) }
  let_it_be(:user1, reload: true) { create(:user, email: "alice@example.com", name: "Alice") }
  let_it_be(:user2) { create(:user, email: "bob@example.com", name: "Bob", plan_type: "pro") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:javascript_include_tag).and_return("")
    sign_in admin
  end

  describe "GET /admin/users" do
    it "renders the users list" do
      get admin_dashboard_users_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("bob@example.com")
    end

    it "filters by plan type" do
      get admin_dashboard_users_path(filter: "pro")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("bob@example.com")
      expect(response.body).not_to include("alice@example.com")
    end

    it "searches by email" do
      get admin_dashboard_users_path(search: "alice")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).not_to include("bob@example.com")
    end

    it "sorts by column" do
      get admin_dashboard_users_path(sort: "email", dir: "asc")
      expect(response).to have_http_status(:ok)
    end

    it "renders and sorts by last login" do
      user1.update_columns(current_sign_in_at: 1.day.ago)
      user2.update_columns(current_sign_in_at: 1.hour.ago)

      get admin_dashboard_users_path(sort: "current_sign_in_at", dir: "desc")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Last login")
      expect(response.body.index("bob@example.com")).to be < response.body.index("alice@example.com")
    end

    it "filters demo accounts" do
      demo = create(:user, email: "bhannajohns+test@gmail.com")
      get admin_dashboard_users_path(filter: "demo")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("bhannajohns+test@gmail.com")
      expect(response.body).not_to include("alice@example.com")
    end

    it "filters Partner Pro accounts and chips their pilot status" do
      partner = create(:user, email: "slp@example.com", plan_type: "partner_pro")
      partner.update_columns(plan_expires_at: 2.days.ago)

      get admin_dashboard_users_path(filter: "partner")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slp@example.com")
      expect(response.body).not_to include("alice@example.com")
      expect(response.body).to include("Pilot ended")
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        get admin_dashboard_users_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root" do
        get admin_dashboard_users_path
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /admin/users/:id" do
    it "renders the user show page" do
      get admin_dashboard_user_path(user1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("Account")
      expect(response.body).to include("Boards")
    end

    it "shows boards for the user" do
      create(:board, user: user1, name: "Test Board")
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("Test Board")
    end

    it "shows communicators for the user" do
      ca = create(:child_account, user: user1, name: "Kid", status: "active")
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("Kid")
    end

    it "shows user settings" do
      user1.update(settings: { "board_limit" => 10 })
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("board_limit")
    end

    it "shows a Partner Pilot card for partner_pro users" do
      partner = create(:user, email: "pilot@example.com", plan_type: "partner_pro")
      partner.update_columns(plan_expires_at: 10.days.from_now)

      get admin_dashboard_user_path(partner)

      expect(response.body).to include("Partner Pilot")
      expect(response.body).to include("Pilot ends")
    end

    it "does not show the Partner Pilot card for non-partner users" do
      get admin_dashboard_user_path(user2) # pro
      expect(response.body).not_to include("Partner Pilot")
    end
  end

  describe "POST /admin/users/:id/adjust_credits" do
    it "adds plan credits and returns the new balance" do
      user1.update_columns(plan_credits_balance: 5, topup_credits_balance: 0)

      expect {
        post adjust_credits_admin_dashboard_user_path(user1),
          params: { amount: 100, source: "plan", reason: "manual top-up" }
      }.to change { CreditTransaction.where(user: user1, kind: "admin_adjust").count }.by(1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["balance"]["plan"]).to eq(105)
      expect(user1.reload.plan_credits_balance).to eq(105)
    end

    it "adjusts topup credits when source is topup" do
      user1.update_columns(plan_credits_balance: 0, topup_credits_balance: 10)
      post adjust_credits_admin_dashboard_user_path(user1),
        params: { amount: -4, source: "topup" }

      expect(response).to have_http_status(:ok)
      expect(user1.reload.topup_credits_balance).to eq(6)
    end

    it "rejects a zero amount" do
      post adjust_credits_admin_dashboard_user_path(user1), params: { amount: 0 }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to be_present
    end

    it "rejects an adjustment that would make the balance negative" do
      user1.update_columns(plan_credits_balance: 5)
      post adjust_credits_admin_dashboard_user_path(user1),
        params: { amount: -10, source: "plan" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user1.reload.plan_credits_balance).to eq(5)
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        post adjust_credits_admin_dashboard_user_path(user1), params: { amount: 100 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root and does not adjust credits" do
        expect {
          post adjust_credits_admin_dashboard_user_path(user2), params: { amount: 100 }
        }.not_to change { user2.reload.plan_credits_balance }
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /admin/users/:id (Stripe links)" do
    it "links the Stripe customer and subscription to the Stripe dashboard in a new tab" do
      user1.update_columns(stripe_customer_id: "cus_test123", stripe_subscription_id: "sub_test456")

      get admin_dashboard_user_path(user1)

      expect(response.body).to include("https://dashboard.stripe.com/customers/cus_test123")
      expect(response.body).to include("https://dashboard.stripe.com/subscriptions/sub_test456")
      expect(response.body).to include('target="_blank"')
    end

    it "shows a dash when there is no Stripe customer" do
      user1.update_columns(stripe_customer_id: nil, stripe_subscription_id: nil)
      get admin_dashboard_user_path(user1)
      expect(response.body).not_to include("dashboard.stripe.com")
    end
  end

  describe "PATCH /admin/users/:id" do
    it "updates name, email, and role" do
      patch admin_dashboard_user_path(user1),
        params: { user: { name: "Alice Updated", email: "alice-new@example.com", role: "partner" } }

      expect(response).to redirect_to(admin_dashboard_user_path(user1))
      user1.reload
      expect(user1.name).to eq("Alice Updated")
      expect(user1.email).to eq("alice-new@example.com")
      expect(user1.role).to eq("partner")
    end

    it "ignores a role outside the whitelist" do
      patch admin_dashboard_user_path(user1), params: { user: { role: "superuser" } }
      expect(user1.reload.role).not_to eq("superuser")
    end

    it "locks the user, setting both the column and settings" do
      patch admin_dashboard_user_path(user1), params: { user: { locked: "1" } }

      user1.reload
      expect(user1.locked).to be(true)
      expect(user1.settings["locked"]).to be(true)
    end

    it "unlocks the user, clearing both the column and settings" do
      user1.update_columns(locked: true)
      user1.update(settings: user1.settings.merge("locked" => true))

      patch admin_dashboard_user_path(user1), params: { user: { locked: "0" } }

      user1.reload
      expect(user1.locked).to be(false)
      expect(user1.settings["locked"]).to be(false)
    end

    it "toggles play_demo" do
      patch admin_dashboard_user_path(user1), params: { user: { play_demo: "0" } }
      expect(user1.reload.play_demo).to be(false)
    end

    it "writes limit overrides into settings without touching plan_type" do
      patch admin_dashboard_user_path(user1),
        params: { user: { board_limit: 42, paid_communicator_limit: 7, demo_communicator_limit: 3 } }

      user1.reload
      expect(user1.settings["board_limit"]).to eq(42)
      expect(user1.settings["paid_communicator_limit"]).to eq(7)
      expect(user1.settings["demo_communicator_limit"]).to eq(3)
      expect(user1.plan_type).to eq("free")
    end

    it "rejects a duplicate email with an alert and leaves the user unchanged" do
      patch admin_dashboard_user_path(user1), params: { user: { email: user2.email } }

      expect(response).to redirect_to(admin_dashboard_user_path(user1))
      expect(flash[:alert]).to be_present
      expect(user1.reload.email).to eq("alice@example.com")
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        patch admin_dashboard_user_path(user1), params: { user: { name: "Nope" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root and does not update" do
        patch admin_dashboard_user_path(user2), params: { user: { name: "Nope" } }
        expect(response).to redirect_to(root_path)
        expect(user2.reload.name).to eq("Bob")
      end
    end
  end

  describe "POST /admin/users/:id/change_plan" do
    it "upgrades free to pro, applying pro limits and an active status" do
      freshie = create(:user, email: "freshie@example.com")

      post change_plan_admin_dashboard_user_path(freshie), params: { plan_type: "pro" }

      expect(response).to redirect_to(admin_dashboard_user_path(freshie))
      expect(flash[:notice]).to include("Plan changed to pro")
      freshie.reload
      expect(freshie.plan_type).to eq("pro")
      expect(freshie.plan_status).to eq("active")
      expect(freshie.settings["board_limit"]).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(freshie.paid_plan?).to be(true)
    end

    it "upgrades a previously-canceled user without leaving them stranded" do
      canceled = create(:user, email: "canceled@example.com")
      canceled.update_columns(plan_status: "canceled")

      post change_plan_admin_dashboard_user_path(canceled), params: { plan_type: "basic" }

      canceled.reload
      expect(canceled.plan_type).to eq("basic")
      expect(canceled.plan_status).to eq("active")
      expect(canceled.plan_stranded?).to be(false)
    end

    it "downgrades to free with full cancellation semantics" do
      pro = create(:user, email: "downgrade@example.com", plan_type: "pro")
      pro.update_columns(stripe_subscription_id: "sub_abc", plan_status: "active")

      expect {
        post change_plan_admin_dashboard_user_path(pro), params: { plan_type: "free" }
      }.to change { CreditTransaction.where(user: pro, kind: "plan_grant").count }.by(1)

      pro.reload
      expect(pro.plan_type).to eq("free")
      expect(pro.paid_plan_type).to eq("pro")
      expect(pro.plan_status).to eq("canceled")
      expect(pro.stripe_subscription_id).to be_nil
    end

    it "runs full partner onboarding for partner_pro" do
      allow(MailchimpService).to receive(:new)
        .and_return(instance_double(MailchimpService, record_new_subscriber: true))
      newbie = create(:user, email: "partner-to-be@example.com")

      post change_plan_admin_dashboard_user_path(newbie), params: { plan_type: "partner_pro" }

      newbie.reload
      expect(newbie.plan_type).to eq("partner_pro")
      expect(newbie.role).to eq("partner")
      expect(newbie.plan_status).to eq("active")
      expect(newbie.plan_expires_at).to be_within(1.day).of(3.months.from_now)
    end

    it "is a no-op when the plan is unchanged" do
      post change_plan_admin_dashboard_user_path(user1), params: { plan_type: "free" }

      expect(flash[:notice]).to include("No change")
      expect(user1.reload.plan_type).to eq("free")
    end

    it "rejects an unknown plan type" do
      post change_plan_admin_dashboard_user_path(user1), params: { plan_type: "platinum" }

      expect(flash[:alert]).to include("Unknown plan type")
      expect(user1.reload.plan_type).to eq("free")
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        post change_plan_admin_dashboard_user_path(user1), params: { plan_type: "pro" }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root and does not change the plan" do
        post change_plan_admin_dashboard_user_path(user2), params: { plan_type: "free" }
        expect(response).to redirect_to(root_path)
        expect(user2.reload.plan_type).to eq("pro")
      end
    end
  end

  describe "DELETE /admin/users/:id" do
    let(:demo) { create(:user, email: "bhannajohns+doomed@gmail.com") }

    it "tombstones a demo account and destroys its content" do
      create(:board, user: demo, name: "Demo Board")

      delete admin_dashboard_user_path(demo)

      expect(response).to redirect_to(admin_dashboard_users_path)
      expect(flash[:notice]).to include("deleted")

      tombstone = User.unscoped.find(demo.id)
      expect(tombstone.deleted_at).to be_present
      expect(tombstone.email).to include("deleted-#{demo.id}")
      expect(Board.where(user_id: demo.id)).to be_empty
    end

    it "refuses to delete a non-demo account" do
      delete admin_dashboard_user_path(user2)

      expect(response).to redirect_to(admin_dashboard_user_path(user2))
      expect(flash[:alert]).to include("Only demo accounts")
      expect(user2.reload.deleted_at).to be_nil
    end

    it "refuses to delete an admin even with a demo-pattern email" do
      demo_admin = create(:admin_user, email: "bhannajohns+admin@gmail.com")

      delete admin_dashboard_user_path(demo_admin)

      expect(flash[:alert]).to include("Only demo accounts")
      expect(demo_admin.reload.deleted_at).to be_nil
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        delete admin_dashboard_user_path(demo)
        expect(response).to redirect_to(new_user_session_path)
        expect(demo.reload.deleted_at).to be_nil
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root without deleting" do
        delete admin_dashboard_user_path(demo)
        expect(response).to redirect_to(root_path)
        expect(demo.reload.deleted_at).to be_nil
      end
    end
  end

  describe "email actions" do
    it "queues a plan-appropriate welcome email and marks it sent" do
      freshie = create(:user, email: "welcome-me@example.com")

      expect {
        post send_welcome_email_admin_dashboard_user_path(freshie)
      }.to have_enqueued_mail(UserMailer, :welcome_free_email)

      expect(response).to redirect_to(admin_dashboard_user_path(freshie))
      expect(flash[:notice]).to include("Welcome email queued")
      expect(freshie.reload.settings["welcome_email_sent"]).to be(true)
    end

    it "queues the pro welcome email for pro users" do
      expect {
        post send_welcome_email_admin_dashboard_user_path(user2)
      }.to have_enqueued_mail(UserMailer, :welcome_pro_email)
    end

    it "queues the pro setup email for pro users" do
      expect {
        post send_setup_email_admin_dashboard_user_path(user2)
      }.to have_enqueued_mail(SetupMailer, :pro_setup_email)
      expect(flash[:notice]).to include("Setup email queued")
    end

    it "queues a temp login email and issues a token" do
      expect {
        post send_temp_login_email_admin_dashboard_user_path(user1)
      }.to have_enqueued_mail(UserMailer, :temporary_login_email)

      user1.reload
      expect(user1.temp_login_token).to be_present
      expect(user1.temp_login_expires_at).to be > Time.current
      expect(flash[:notice]).to include("Temporary login email queued")
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root without sending" do
        expect {
          post send_welcome_email_admin_dashboard_user_path(user2)
        }.not_to have_enqueued_mail
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
