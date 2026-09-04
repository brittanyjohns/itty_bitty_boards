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

    it "shows each user's signup source" do
      create(:user, email: "ios-signup@example.com", settings: { "signup_platform" => "ios" })

      get admin_dashboard_users_path

      expect(response.body).to include("Source")
      expect(response.body).to include("iOS")
    end

    it "filters by signup platform" do
      create(:user, email: "ios-only@example.com", settings: { "signup_platform" => "ios" })
      create(:user, email: "web-only@example.com", settings: { "signup_platform" => "web" })

      get admin_dashboard_users_path(filter: "ios")

      expect(response.body).to include("ios-only@example.com")
      expect(response.body).not_to include("web-only@example.com")
    end

    it "sorts by signup platform" do
      create(:user, email: "ios-sorted@example.com", settings: { "signup_platform" => "ios" })

      get admin_dashboard_users_path(sort: "signup_platform", dir: "asc")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ios-sorted@example.com")
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

    it "badges a trialing account with its end date" do
      trialist = create(:user, email: "trialing@example.com", plan_type: "pro",
                               plan_status: "trialing", stripe_subscription_id: "sub_trial")
      trialist.update_columns(settings: trialist.settings.merge("trial_ends_at" => 6.days.from_now.iso8601,
                                                               "has_payment_method" => true))

      get admin_dashboard_users_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Trialing")
      expect(response.body).to include(6.days.from_now.strftime("%b %-d, %Y"))
    end

    it "flags a Stripe trialist with no card on file" do
      trialist = create(:user, email: "nocard@example.com", plan_type: "basic",
                               plan_status: "trialing", stripe_subscription_id: "sub_nocard")
      trialist.update_columns(settings: trialist.settings.merge("trial_ends_at" => 2.days.from_now.iso8601))

      get admin_dashboard_users_path

      expect(response.body).to include("no card")
      expect(response.body).to include("Ends soon")
    end

    it "falls back to plan_expires_at when no trial_ends_at is stored" do
      partner = create(:user, email: "pilot@example.com", plan_type: "partner_pro", plan_status: "trialing")
      partner.update_columns(plan_expires_at: 30.days.from_now)

      get admin_dashboard_users_path(filter: "trial")

      expect(response.body).to include("pilot@example.com")
      expect(response.body).to include(30.days.from_now.strftime("%b %-d, %Y"))
    end

    it "filters to trialing accounts across both providers and the legacy cohort" do
      stripe = create(:user, email: "stripe-trial@example.com", plan_status: "trialing",
                             stripe_subscription_id: "sub_x")
      legacy = create(:user, email: "soft-trial@example.com", plan_type: "basic_trial")

      get admin_dashboard_users_path(filter: "trial")

      expect(response.body).to include(stripe.email)
      expect(response.body).to include(legacy.email)
      expect(response.body).not_to include("alice@example.com")
    end

    it "hides demo accounts when the toggle is on" do
      create(:user, email: "bhannajohns+hidden@gmail.com")

      get admin_dashboard_users_path(hide_demo: "1")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("bhannajohns+hidden@gmail.com")
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("demo accounts hidden")
    end

    it "keeps the toggle off by default" do
      create(:user, email: "bhannajohns+visible@gmail.com")

      get admin_dashboard_users_path

      expect(response.body).to include("bhannajohns+visible@gmail.com")
    end

    it "lets the explicit demo filter win over the hide toggle" do
      create(:user, email: "bhannajohns+both@gmail.com")

      get admin_dashboard_users_path(filter: "demo", hide_demo: "1")

      expect(response.body).to include("bhannajohns+both@gmail.com")
    end

    it "carries the toggle through the column sort links" do
      get admin_dashboard_users_path(hide_demo: "1")

      expect(response.body).to include("hide_demo=1")
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

    it "renders live Stripe state on the Partner Pilot card, flagging a non-partner price" do
      partner = create(:user, email: "stripe-state@example.com", plan_type: "partner_pro")
      partner.update_columns(stripe_subscription_id: "sub_show", plan_expires_at: 2.months.from_now)
      allow(Stripe::Subscription).to receive(:retrieve).and_return(
        OpenStruct.new(
          id: "sub_show", status: "active", cancel_at_period_end: false, trial_end: nil, metadata: {},
          items: OpenStruct.new(data: [
            OpenStruct.new(id: "si_plan", quantity: 1, price: OpenStruct.new(
              id: "price_basic", metadata: { "plan_type" => "basic" },
              recurring: OpenStruct.new(interval: "month"), unit_amount: 1500,
            )),
          ]),
        ),
      )

      get admin_dashboard_user_path(partner)

      expect(response.body).to include("sub_show").and include("price_basic")
      expect(response.body).to include("not the Partner Pro price")
    end

    it "still renders the user page when Stripe is unreachable" do
      partner = create(:user, email: "stripe-down@example.com", plan_type: "partner_pro")
      partner.update_columns(stripe_subscription_id: "sub_down")
      allow(Stripe::Subscription).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("down"))

      get admin_dashboard_user_path(partner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Stripe unavailable")
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

    it "writes voice and display-preference settings" do
      patch admin_dashboard_user_path(user1),
        params: { user: {
          voice: { name: "nova", language: "es-US" },
          wait_to_speak: "1", disable_audit_logging: "1",
          enable_text_display: "1", enable_image_display: "0",
        } }

      user1.reload
      expect(user1.settings["voice"]).to include("name" => "nova", "language" => "es-US")
      expect(user1.settings["wait_to_speak"]).to be(true)
      expect(user1.settings["disable_audit_logging"]).to be(true)
      expect(user1.settings["enable_text_display"]).to be(true)
      expect(user1.settings["enable_image_display"]).to be(false)
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
      # Resolved from plan_type, never stamped into settings (#796).
      expect(freshie.board_limit).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(freshie.settings).not_to have_key("board_limit")
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

    context "partner_pro Stripe sync" do
      around do |example|
        original = ENV["STRIPE_PRICE_PARTNER_PRO"]
        ENV["STRIPE_PRICE_PARTNER_PRO"] = "price_partner_test"
        example.run
      ensure
        ENV["STRIPE_PRICE_PARTNER_PRO"] = original
      end

      before do
        allow(MailchimpService).to receive(:new)
          .and_return(instance_double(MailchimpService, record_new_subscriber: true))
      end

      let(:payer) do
        create(:user, email: "payer@example.com", plan_type: "basic").tap do |u|
          u.update_columns(stripe_customer_id: "cus_x", stripe_subscription_id: "sub_x")
        end
      end

      def stub_existing_subscription(price_id: "price_basic")
        allow(Stripe::Subscription).to receive(:retrieve).and_return(
          OpenStruct.new(
            id: "sub_x", status: "active", cancel_at_period_end: false, metadata: {},
            items: OpenStruct.new(data: [
              OpenStruct.new(id: "si_plan", quantity: 1, price: OpenStruct.new(
                id: price_id, metadata: { "plan_type" => "basic" },
                recurring: OpenStruct.new(interval: "month"), unit_amount: 1500,
              )),
            ]),
          ),
        )
      end

      it "moves an existing subscription onto the partner price and says so" do
        stub_existing_subscription
        expect(Stripe::Subscription).to receive(:update)
          .with("sub_x", hash_including(items: [{ id: "si_plan", price: "price_partner_test", quantity: 1 }]))
          .and_return(double(id: "sub_x"))

        post change_plan_admin_dashboard_user_path(payer), params: { plan_type: "partner_pro" }

        expect(payer.reload.plan_type).to eq("partner_pro")
        expect(flash[:notice]).to include("sub_x").and include("moved onto the Partner Pro price")
        expect(flash[:notice]).to include("price_basic")
      end

      it "reports a Stripe failure as an alert, while the local flip still lands" do
        stub_existing_subscription
        allow(Stripe::Subscription).to receive(:update).and_raise(Stripe::StripeError.new("card_declined"))

        post change_plan_admin_dashboard_user_path(payer), params: { plan_type: "partner_pro" }

        expect(payer.reload.plan_type).to eq("partner_pro")
        expect(payer.stripe_subscription_id).to eq("sub_x")
        expect(flash[:alert]).to include("Stripe failed").and include("card_declined")
      end

      it "creates a fresh subscription when the stored one is gone from Stripe" do
        allow(Stripe::Subscription).to receive(:retrieve)
          .and_raise(Stripe::InvalidRequestError.new("no sub", "id", code: "resource_missing"))
        allow(Stripe::Subscription).to receive(:create).and_return(double(id: "sub_fresh"))

        post change_plan_admin_dashboard_user_path(payer), params: { plan_type: "partner_pro" }

        expect(payer.reload.stripe_subscription_id).to eq("sub_fresh")
        expect(flash[:notice]).to include("Created Stripe trial subscription sub_fresh")
      end

      it "alerts when the partner price is not configured" do
        ENV["STRIPE_PRICE_PARTNER_PRO"] = ""

        post change_plan_admin_dashboard_user_path(payer), params: { plan_type: "partner_pro" }

        expect(payer.reload.plan_type).to eq("partner_pro")
        expect(flash[:alert]).to include("STRIPE_PRICE_PARTNER_PRO")
      end

      # A failed swap leaves the user partner_pro locally; without the exemption
      # the no-change guard would make retrying impossible from this page.
      it "can be re-run on a user who is already partner_pro" do
        stub_existing_subscription
        payer.update_columns(plan_type: "partner_pro")
        expect(Stripe::Subscription).to receive(:update).and_return(double(id: "sub_x"))

        post change_plan_admin_dashboard_user_path(payer), params: { plan_type: "partner_pro" }

        expect(flash[:notice]).to include("moved onto the Partner Pro price")
      end
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

    it "queues the partner welcome email" do
      partner = create(:user, email: "partner@example.com", role: "partner")

      expect {
        post send_partner_welcome_email_admin_dashboard_user_path(partner)
      }.to have_enqueued_mail(PartnerMailer, :welcome_email)

      expect(response).to redirect_to(admin_dashboard_user_path(partner))
      expect(flash[:notice]).to include("Partner welcome email queued")
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

  describe "GET /admin/users/export" do
    it "streams a CSV of all users" do
      get export_admin_dashboard_users_path

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.body).to include(user1.email)
      expect(response.body).to include(user2.email)
    end
  end

  describe "POST /admin/users/destroy_users" do
    it "bulk-deletes only the demo accounts among the selected ids" do
      demo1 = create(:user, email: "bhannajohns+demo1@gmail.com")
      demo2 = create(:user, email: "bhannajohns+demo2@gmail.com")

      post destroy_users_admin_dashboard_users_path, params: { user_ids: [demo1.id, demo2.id, user1.id] }

      expect(response).to redirect_to(admin_dashboard_users_path)
      expect(demo1.reload.soft_deleted?).to be(true)
      expect(demo2.reload.soft_deleted?).to be(true)
      expect(user1.reload.soft_deleted?).to be(false)
      expect(flash[:notice]).to include("Deleted 2 demo account")
      expect(flash[:notice]).to include("Skipped 1")
    end

    # Every real signup has a NULL role — nothing defaults the column — so the
    # factory's explicit `role: "user"` hides the exact case the bulk delete
    # used to drop on the floor.
    it "deletes a demo account whose role is NULL" do
      demo = create(:user, email: "bhannajohns+nilrole@gmail.com", role: nil)

      post destroy_users_admin_dashboard_users_path, params: { user_ids: [demo.id] }

      expect(demo.reload.soft_deleted?).to be(true)
      expect(flash[:notice]).to include("Deleted 1 demo account")
      expect(flash[:notice]).not_to include("Skipped")
    end

    it "still refuses an admin with a demo-pattern email" do
      demo_admin = create(:admin_user, email: "bhannajohns+bulkadmin@gmail.com")

      post destroy_users_admin_dashboard_users_path, params: { user_ids: [demo_admin.id] }

      expect(demo_admin.reload.soft_deleted?).to be(false)
      expect(flash[:notice]).to include("Deleted 0 demo account")
    end

    it "alerts when nothing is selected" do
      post destroy_users_admin_dashboard_users_path, params: {}

      expect(response).to redirect_to(admin_dashboard_users_path)
      expect(flash[:alert]).to include("No users selected")
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root without deleting" do
        demo = create(:user, email: "bhannajohns+demo3@gmail.com")

        post destroy_users_admin_dashboard_users_path, params: { user_ids: [demo.id] }

        expect(response).to redirect_to(root_path)
        expect(demo.reload.soft_deleted?).to be(false)
      end
    end
  end
end
