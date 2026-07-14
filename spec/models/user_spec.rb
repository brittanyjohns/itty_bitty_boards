# == Schema Information
#
# Table name: users
#
#  id                              :bigint           not null, primary key
#  email                           :string           default(""), not null
#  encrypted_password              :string           default(""), not null
#  reset_password_token            :string
#  reset_password_sent_at          :datetime
#  remember_created_at             :datetime
#  sign_in_count                   :integer          default(0), not null
#  current_sign_in_at              :datetime
#  last_sign_in_at                 :datetime
#  current_sign_in_ip              :string
#  last_sign_in_ip                 :string
#  name                            :string
#  role                            :string
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  tokens                          :integer          default(0)
#  stripe_customer_id              :string
#  authentication_token            :string
#  jti                             :string           not null
#  invitation_token                :string
#  invitation_created_at           :datetime
#  invitation_sent_at              :datetime
#  invitation_accepted_at          :datetime
#  invitation_limit                :integer
#  invited_by_id                   :integer
#  invited_by_type                 :string
#  current_team_id                 :bigint
#  play_demo                       :boolean          default(TRUE)
#  settings                        :jsonb
#  base_words                      :string           default([]), is an Array
#  plan_type                       :string           default("free")
#  plan_expires_at                 :datetime
#  plan_status                     :string           default("active")
#  monthly_price                   :decimal(8, 2)    default(0.0)
#  yearly_price                    :decimal(8, 2)    default(0.0)
#  total_plan_cost                 :decimal(8, 2)    default(0.0)
#  uuid                            :uuid
#  child_lookup_key                :string
#  locked                          :boolean          default(FALSE)
#  organization_id                 :bigint
#  vendor_id                       :bigint
#  stripe_subscription_id          :string
#  temp_login_token                :string
#  temp_login_expires_at           :datetime
#  force_password_reset            :boolean          default(FALSE)
#  paid_plan_type                  :string
#  delete_account_token            :string
#  delete_account_token_expires_at :datetime
#  deleted_at                      :datetime
#  layout                          :jsonb
#  confirmation_token              :string
#  confirmed_at                    :datetime
#  confirmation_sent_at            :datetime
#  unconfirmed_email               :string
#
require "rails_helper"

RSpec.describe User, type: :model do
  include ActiveJob::TestHelper

  describe "Partner Pro is Pro-equivalent" do
    let(:partner) { FactoryBot.create(:user, plan_type: "partner_pro", role: "partner") }

    it "counts as pro? and paid_plan?" do
      expect(partner.pro?).to be(true)
      expect(partner.paid_plan?).to be(true)
    end

    it "reports partner_pro? true (pro? && role partner)" do
      expect(partner.partner_pro?).to be(true)
    end

    it "gets the Pro supporter limit (5, not 2)" do
      expect(partner.supporter_limit).to eq(5)
    end

    it "gets Pro board/communicator/board-set limits" do
      expect(partner.board_limit).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(partner.board_group_limit).to eq(User::PRO_PLAN_LIMITS["board_group_limit"])
      expect(partner.settings["paid_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["paid_communicator_limit"])
    end
  end

  describe ".handle_new_partner_pro_subscription" do
    let(:user) { FactoryBot.create(:user) }

    it "records the subscriber with the stable 'Partner Program' tag and the monthly cohort tag" do
      mailchimp = instance_double(MailchimpService)
      allow(MailchimpService).to receive(:new).and_return(mailchimp)

      expect(mailchimp).to receive(:record_new_subscriber)
        .with(user, tags: ["Partner Program", user.get_partner_group])

      User.handle_new_partner_pro_subscription(user)
    end

    it "does not raise if the Mailchimp call fails (rescued)" do
      mailchimp = instance_double(MailchimpService)
      allow(MailchimpService).to receive(:new).and_return(mailchimp)
      allow(mailchimp).to receive(:record_new_subscriber).and_raise(StandardError, "boom")

      expect { User.handle_new_partner_pro_subscription(user) }.not_to raise_error
      expect(user.reload.role).to eq("partner")
    end
  end

  describe "Partner Pro trial subscription (Stripe)" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_test") }

    around do |example|
      original = ENV["STRIPE_PRICE_PARTNER_PRO"]
      ENV["STRIPE_PRICE_PARTNER_PRO"] = "price_partner_test"
      example.run
    ensure
      ENV["STRIPE_PRICE_PARTNER_PRO"] = original
    end

    describe "#ensure_partner_pro_trial_subscription!" do
      it "creates a no-card trial subscription on the partner price and stores the id" do
        trial_end = 3.months.from_now
        expect(Stripe::Subscription).to receive(:create).with(
          hash_including(
            customer: "cus_test",
            items: [{ price: "price_partner_test" }],
            trial_end: trial_end.to_i,
            trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
          ),
        ).and_return(double(id: "sub_123"))

        user.ensure_partner_pro_trial_subscription!(trial_end: trial_end)
        expect(user.reload.stripe_subscription_id).to eq("sub_123")
      end

      it "is a no-op when a subscription already exists" do
        user.update_columns(stripe_subscription_id: "sub_existing")
        expect(Stripe::Subscription).not_to receive(:create)

        expect(user.ensure_partner_pro_trial_subscription!(trial_end: 3.months.from_now))
          .to eq("sub_existing")
      end

      it "returns nil and skips Stripe when the price env is unset" do
        ENV["STRIPE_PRICE_PARTNER_PRO"] = ""
        expect(Stripe::Subscription).not_to receive(:create)

        expect(user.ensure_partner_pro_trial_subscription!(trial_end: 3.months.from_now)).to be_nil
      end

      it "fails soft on a Stripe error (never raises, leaves the id nil)" do
        allow(Stripe::Subscription).to receive(:create).and_raise(Stripe::StripeError.new("boom"))

        expect { user.ensure_partner_pro_trial_subscription!(trial_end: 3.months.from_now) }
          .not_to raise_error
        expect(user.reload.stripe_subscription_id).to be_nil
      end
    end

    describe "#extend_partner_pro_trial!" do
      it "moves both plan_expires_at and the Stripe trial_end" do
        user.update_columns(stripe_subscription_id: "sub_123", plan_expires_at: 1.month.from_now)
        new_end = 4.months.from_now
        expect(Stripe::Subscription).to receive(:update).with(
          "sub_123", hash_including(trial_end: new_end.to_i),
        ).and_return(double(id: "sub_123"))

        user.extend_partner_pro_trial!(new_end: new_end)
        expect(user.reload.plan_expires_at).to be_within(1.second).of(new_end)
      end

      it "updates plan_expires_at only when there is no Stripe subscription" do
        new_end = 4.months.from_now
        expect(Stripe::Subscription).not_to receive(:update)

        expect(user.extend_partner_pro_trial!(new_end: new_end)).to be_nil
        expect(user.reload.plan_expires_at).to be_within(1.second).of(new_end)
      end
    end

    describe ".handle_new_partner_pro_subscription with Stripe" do
      before do
        allow(MailchimpService).to receive(:new)
          .and_return(instance_double(MailchimpService, record_new_subscriber: true))
      end

      it "creates the trial subscription and pre-seeds the plan welcome as sent" do
        allow(Stripe::Subscription).to receive(:create).and_return(double(id: "sub_abc"))

        User.handle_new_partner_pro_subscription(user)

        expect(user.reload.stripe_subscription_id).to eq("sub_abc")
        expect(Array(user.settings["plan_welcome_sent_for"])).to include("partner_pro")
        expect(user.plan_expires_at).to be_present
      end

      it "still provisions the partner (role + credits) when Stripe creation fails" do
        allow(Stripe::Subscription).to receive(:create).and_raise(Stripe::StripeError.new("down"))

        expect { User.handle_new_partner_pro_subscription(user) }.not_to raise_error
        expect(user.reload.role).to eq("partner")
        expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("partner_pro"))
      end
    end
  end

  after(:all) do
    Team.destroy_all
    User.destroy_all
  end
  context "validation" do
    subject(:user) { FactoryBot.build(:user) }
    it "is invalid without a email" do
      user.email = nil
      expect(user.save).to be_falsey
    end

    it "is valid with name and email" do
      user.name = "Some name"
      user.email = "email@test.com"
      expect(user.save).to be_truthy
    end
  end
  context "plan_type checks" do
    it "defaults to free plan on signup (no-CC soft trial removed)" do
      user = FactoryBot.create(:user)
      expect(user.plan_type).to eq("free")
    end

    it "applies Free-tier limits on signup" do
      user = FactoryBot.create(:user)
      expect(user.settings["board_limit"]).to eq(User::FREE_PLAN_LIMITS["board_limit"])
      expect(user.settings["paid_communicator_limit"]).to eq(User::FREE_PLAN_LIMITS["paid_communicator_limit"])
      expect(user.settings["demo_communicator_limit"]).to eq(User::FREE_PLAN_LIMITS["demo_communicator_limit"])
      # ai_monthly_limit was removed — AI is gated by the credit ledger now.
      expect(user.settings).not_to have_key("ai_monthly_limit")
    end

    it "does not override an explicitly set plan_type on create" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.plan_type).to eq("pro")
    end

    it "does not change plan_type on subsequent saves" do
      user = FactoryBot.create(:user)
      user.update!(name: "Updated")
      expect(user.plan_type).to eq("free")
    end

    it "recognizes pro plan" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.pro?).to be true
      expect(user.free?).to be false
    end

    it "recognizes basic plan" do
      user = FactoryBot.create(:user, plan_type: "basic")
      expect(user.basic?).to be true
    end

    it "premium? returns false for free plan" do
      user = FactoryBot.create(:user, plan_type: "free")
      expect(user.premium?).to be false
    end

    it "premium? returns true when plan_type includes 'premium'" do
      user = FactoryBot.create(:user, plan_type: "premium")
      expect(user.premium?).to be true
    end
  end

  context "initial plan-credit grant on signup" do
    it "grants the free allowance (25) by default since new users land on free" do
      user = FactoryBot.create(:user)
      expect(user.plan_type).to eq("free")
      expect(user.plan_credits_balance).to eq(25)
      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
    end

    it "grants the basic allowance (400) when plan_type is explicitly basic" do
      user = FactoryBot.create(:user, plan_type: "basic")
      expect(user.plan_credits_balance).to eq(400)
    end

    it "grants the pro allowance (1500) when plan_type is explicitly pro" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.plan_credits_balance).to eq(1500)
    end

    it "sets plan_credits_reset_at = 30 days from now for free users (default)" do
      user = FactoryBot.create(:user)
      expect(user.plan_credits_reset_at).to be_within(5.seconds).of(30.days.from_now)
    end

    it "does not grant credits to admins" do
      admin = FactoryBot.create(:admin_user)
      expect(admin.plan_credits_balance).to eq(0)
      expect(admin.credit_transactions.where(kind: "plan_grant")).to be_empty
    end
  end

  # Regression guard for drafts/drop-basic-trial-option-a.md: the no-CC
  # basic_trial soft trial was removed, so every brand-new signup must land on
  # Free with Free limits and the 25-credit initial grant — no 400-credit trial.
  context "fresh signup (no-CC soft trial removed)" do
    it "lands on free with Free limits, a communicator slot, and a 25-credit grant" do
      user = FactoryBot.create(:user)

      expect(user.plan_type).to eq("free")
      expect(user.settings["board_limit"]).to eq(User::FREE_PLAN_LIMITS["board_limit"])
      expect(user.settings).not_to have_key("ai_monthly_limit")
      # At least the Free-tier communicator slot so the MySpeak wizard doesn't 403.
      expect(user.settings["paid_communicator_limit"])
        .to eq(User::FREE_PLAN_LIMITS["paid_communicator_limit"])
      expect(user.settings["paid_communicator_limit"].to_i).to be >= 1

      expect(user.plan_credits_balance).to eq(25)
      expect(user.credit_transactions.where(kind: "plan_grant").count).to eq(1)
    end
  end

  context "invite_new_user_to_team!" do
    let(:current_user) { FactoryBot.create(:user) }

    let(:user_to_invite_email) { "user@email.com" }
    let(:team) { FactoryBot.create(:team) }

    subject(:invite_new_user_to_team!) do
      # current_user.invite_new_user_to_team!(user_to_invite_email, team)
      @user = User.create_from_email(user_to_invite_email, nil, current_user.id)
      team.upsert_member!(@user) if @user
    end
    before do
      # Create a team and add the current user to it
      team.upsert_member!(current_user, "admin")
      allow(User).to receive(:create_stripe_customer).and_return("cus_test_#{SecureRandom.hex(4)}")
    end
    it "adds the invited user to the team" do
      subject
      expect(team.users.count).to eq(2)
      expect(team.users.last.email).to eq(user_to_invite_email)
    end

    it "sets the invited_by_id for the invited user" do
      subject
      invited_user = User.find_by(email: user_to_invite_email)
      expect(invited_user).not_to be_nil
      expect(invited_user.invited_by_id).to eq(current_user.id)
    end

    it "sends an invitation email to the invited user" do
      expect {
        perform_enqueued_jobs { subject }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
      last_email = ActionMailer::Base.deliveries.last
      expect(last_email.to).to include(user_to_invite_email)
      expect(last_email.subject).to include("You have been invited to join SpeakAnyWay AAC!")
    end
  end

  context "#i18n_locale" do
    let(:user) { FactoryBot.create(:user) }

    def set_voice_language(value)
      user.settings ||= {}
      user.settings["voice"] ||= {}
      user.settings["voice"]["language"] = value
      user.save!
    end

    it "returns :en by default" do
      expect(user.i18n_locale).to eq(:en)
    end

    it "strips BCP-47 region tag" do
      set_voice_language("es-US")
      expect(user.i18n_locale).to eq(:es)
    end

    it "handles underscore-separated locale" do
      set_voice_language("fr_FR")
      expect(user.i18n_locale).to eq(:fr)
    end

    it "accepts bare ISO 639-1 codes" do
      set_voice_language("de")
      expect(user.i18n_locale).to eq(:de)
    end

    it "maps legacy human-readable names to ISO codes" do
      set_voice_language("Spanish")
      expect(user.i18n_locale).to eq(:es)
    end

    it "is case-insensitive for legacy names" do
      set_voice_language("FRENCH")
      expect(user.i18n_locale).to eq(:fr)
    end

    it "falls back to :en for unsupported languages" do
      set_voice_language("xx-YY")
      expect(user.i18n_locale).to eq(:en)
    end

    it "falls back to :en for empty values" do
      set_voice_language("   ")
      expect(user.i18n_locale).to eq(:en)
    end
  end

  context "admin views expose ai_credits" do
    it "includes the credit balance in admin_api_view" do
      user = FactoryBot.create(:user, plan_type: "pro")
      credits = user.admin_api_view["ai_credits"]
      expect(credits[:total]).to eq(1500)
      expect(credits[:plan]).to eq(1500)
      expect(credits[:topup]).to eq(0)
    end

    it "includes the credit balance in admin_index_view" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.admin_index_view["ai_credits"][:total]).to eq(1500)
    end

    it "reflects topup credits in the total" do
      user = FactoryBot.create(:user, plan_type: "free", created_at: 30.days.ago)
      CreditService.grant_topup!(user, amount: 25)
      credits = user.reload.admin_api_view["ai_credits"]
      expect(credits[:topup]).to eq(25)
      expect(credits[:total]).to eq(credits[:plan] + 25)
    end
  end

  describe "#api_view plan_status" do
    it "includes plan_status in the response" do
      user = FactoryBot.create(:user, plan_type: "basic", plan_status: "trialing")
      expect(user.api_view[:plan_status]).to eq("trialing")
    end

    it "returns nil plan_status when not set" do
      user = FactoryBot.create(:user, plan_status: nil)
      expect(user.api_view).to have_key(:plan_status)
      expect(user.api_view[:plan_status]).to be_nil
    end
  end

  describe "#api_view has_boards flag" do
    it "is false when the user has no boards" do
      user = FactoryBot.create(:free_user)
      expect(user.api_view[:has_boards]).to eq(false)
      expect(user.api_view[:board_count]).to eq(0)
    end

    it "is true when the user has at least one board" do
      user = FactoryBot.create(:free_user)
      FactoryBot.create(:board, user: user)
      expect(user.api_view[:has_boards]).to eq(true)
      expect(user.api_view[:board_count]).to eq(1)
    end
  end

  describe "#api_view board set (BoardGroup) usage" do
    it "exposes board_group_limit and board_group_count" do
      user = FactoryBot.create(:free_user)
      view = user.api_view
      expect(view).to have_key(:board_group_limit)
      expect(view).to have_key(:board_group_count)
      expect(view[:board_group_limit]).to eq(user.board_group_limit)
      expect(view[:board_group_count]).to eq(0)
    end

    it "counts a builder board set as one group" do
      user = FactoryBot.create(:free_user)
      BoardGroup.create!(name: "Built set", user: user, builder: true)
      expect(user.api_view[:board_group_count]).to eq(1)
    end

    it "excludes predefined (admin-curated) sets from the count" do
      user = FactoryBot.create(:free_user)
      BoardGroup.create!(name: "Mine", user: user)
      BoardGroup.create!(name: "Curated", user: user, predefined: true)
      expect(user.api_view[:board_group_count]).to eq(1)
    end
  end

  describe "#ensure_minimum_communicator_slot!" do
    it "bumps a 0 limit up to the free-plan default" do
      user = FactoryBot.create(:free_user)
      user.update_columns(settings: { "paid_communicator_limit" => 0 })

      expect { user.ensure_minimum_communicator_slot! }
        .to change { user.reload.settings["paid_communicator_limit"] }
        .from(0).to(User::FREE_PLAN_LIMITS["paid_communicator_limit"])
    end

    it "initializes settings when paid_communicator_limit is missing" do
      user = FactoryBot.create(:free_user)
      user.update_columns(settings: {})

      user.ensure_minimum_communicator_slot!

      expect(user.reload.settings["paid_communicator_limit"])
        .to eq(User::FREE_PLAN_LIMITS["paid_communicator_limit"])
    end

    it "leaves higher limits alone (e.g. basic/pro)" do
      user = FactoryBot.create(:free_user)
      user.update_columns(settings: { "paid_communicator_limit" => 3 })

      user.ensure_minimum_communicator_slot!

      expect(user.reload.settings["paid_communicator_limit"]).to eq(3)
    end
  end

  describe "#send_free_setup_email" do
    let(:user) { FactoryBot.create(:user, plan_type: "free") }

    it "delivers UserMailer#welcome_free_email" do
      expect {
        perform_enqueued_jobs { user.send_free_setup_email }
      }.to change { ActionMailer::Base.deliveries.size }.by(1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([user.email])
    end
  end

  describe "#plan_stranded? / #reconcile_stranded_plan!" do
    User::UNPAID_STATUSES.each do |status|
      it "flags a paid plan_type with unpaid status=#{status} as stranded" do
        user = FactoryBot.build(:user, plan_type: "basic", plan_status: status)
        expect(user.plan_stranded?).to be(true)
      end
    end

    it "is not stranded when actively paid" do
      user = FactoryBot.build(:user, plan_type: "pro", plan_status: "active")
      expect(user.plan_stranded?).to be(false)
    end

    it "is not stranded on free or basic_trial even with an unpaid status" do
      expect(FactoryBot.build(:user, plan_type: "free", plan_status: "canceled").plan_stranded?).to be(false)
      expect(FactoryBot.build(:user, plan_type: "basic_trial", plan_status: "paused").plan_stranded?).to be(false)
    end

    it "is never stranded for admins" do
      user = FactoryBot.build(:user, role: "admin", plan_type: "basic", plan_status: "paused")
      expect(user.plan_stranded?).to be(false)
    end

    it "reconciles a stranded user to Free with the free credit allowance" do
      user = FactoryBot.create(:user, plan_type: "basic", plan_status: "paused",
        stripe_subscription_id: "sub_x", plan_credits_balance: 0)

      expect(user.reconcile_stranded_plan!).to be(true)

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.paid_plan_type).to eq("basic")
      expect(user.plan_status).to eq("paused") # status reason preserved
      expect(user.stripe_subscription_id).to be_nil
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
    end

    it "is a no-op (returns false) for a healthy user" do
      user = FactoryBot.create(:user, plan_type: "basic", plan_status: "active")
      expect(user.reconcile_stranded_plan!).to be(false)
      expect(user.reload.plan_type).to eq("basic")
    end

    it "never raises on sign-in path — rescues internally" do
      user = FactoryBot.create(:user, plan_type: "basic", plan_status: "paused")
      allow(Billing::PlanTransitions).to receive(:apply_free_plan).and_raise(StandardError, "boom")
      expect(user.reconcile_stranded_plan!).to be(false)
    end
  end

  # #433 — free_trial? measures trial *state*, not raw account age. A user who
  # converted to a paid plan within their first 14 days is no longer on a free
  # trial.
  describe "#free_trial?" do
    it "is true for a free user within the 14-day signup window" do
      user = FactoryBot.build(:user, plan_type: "free", created_at: 5.days.ago)
      expect(user.free_trial?).to be(true)
    end

    it "is false for a free user past the 14-day window" do
      user = FactoryBot.build(:user, plan_type: "free", created_at: 20.days.ago)
      expect(user.free_trial?).to be(false)
    end

    it "is false for a paid (pro) user within the window — age is not trial state" do
      user = FactoryBot.build(:user, plan_type: "pro", created_at: 5.days.ago)
      expect(user.paid_plan?).to be(true)
      expect(user.free_trial?).to be(false)
    end

    it "is false for a paid (basic) user within the window" do
      user = FactoryBot.build(:user, plan_type: "basic", created_at: 5.days.ago)
      expect(user.free_trial?).to be(false)
    end

    it "is false for a basic_trial user (paid_plan? treats the soft trial as paid)" do
      user = FactoryBot.build(:user, plan_type: "basic_trial", created_at: 5.days.ago)
      expect(user.paid_plan?).to be(true)
      expect(user.free_trial?).to be(false)
    end
  end
end
