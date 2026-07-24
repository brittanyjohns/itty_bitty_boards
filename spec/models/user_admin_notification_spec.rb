require "rails_helper"

RSpec.describe "User admin signup notification" do
  include ActiveJob::TestHelper

  let(:user) { FactoryBot.create(:user) }

  describe "#record_signup_context!" do
    it "stores the platform and method" do
      user.record_signup_context!(platform: "ios", method: "standard")
      expect(user.reload.settings["signup_platform"]).to eq("ios")
      expect(user.settings["signup_method"]).to eq("standard")
    end

    it "defaults a blank platform to web" do
      user.record_signup_context!(platform: "", method: "email_only")
      expect(user.reload.settings["signup_platform"]).to eq("web")
    end

    it "persists on its own without a later save" do
      user.record_signup_context!(platform: "android", method: "standard")
      expect(User.find(user.id).settings["signup_platform"]).to eq("android")
    end
  end

  describe "#notify_admin_of_signup!" do
    it "enqueues the admin new-user email" do
      expect {
        user.notify_admin_of_signup!
      }.to have_enqueued_mail(AdminMailer, :new_user_email).with(user)
    end

    it "flags the user so it cannot send twice" do
      user.notify_admin_of_signup!
      expect(user.reload.settings["admin_new_user_notified"]).to be(true)
      expect {
        user.notify_admin_of_signup!
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify for an admin account" do
      admin = FactoryBot.create(:admin_user)
      expect {
        admin.notify_admin_of_signup!
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "swallows and logs a mailer failure instead of raising" do
      allow(AdminMailer).to receive(:new_user_email).and_raise(StandardError, "smtp down")
      expect(Rails.logger).to receive(:error).with(/Admin new-user notification failed/)
      expect { user.notify_admin_of_signup! }.not_to raise_error
    end
  end

  describe "welcome-email paths no longer notify the admin" do
    before { allow_any_instance_of(User).to receive(:update_mailchimp_subscription) }

    it "does not notify from send_welcome_email" do
      expect {
        user.send_welcome_email("free")
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify from send_welcome_receipt_email" do
      expect {
        user.send_welcome_receipt_email
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify from send_general_welcome_email" do
      expect {
        user.send_general_welcome_email
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end
  end

  describe "#send_plan_welcome_email_once!" do
    before { allow_any_instance_of(User).to receive(:update_mailchimp_subscription) }

    let(:paid_user) { FactoryBot.create(:user, plan_type: "pro") }

    it "enqueues the plan change email for a paid plan" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "derives from_plan from the previously welcomed plan" do
      paid_user.settings["plan_welcome_sent_for"] = ["basic"]
      paid_user.save
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "basic", to_plan: "pro", source: "stripe")
    end

    it "falls back to free when nothing was welcomed before" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "revenuecat")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "free", to_plan: "pro", source: "revenuecat")
    end

    it "defaults source to unknown when the caller omits it" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "free", to_plan: "pro", source: "unknown")
    end

    it "does not enqueue a plan change email for a free plan" do
      expect {
        FactoryBot.create(:user).send_plan_welcome_email_once!("free")
      }.not_to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "does not re-enqueue for a plan already welcomed" do
      paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.not_to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "never enqueues the new-user alert" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end
  end
end
