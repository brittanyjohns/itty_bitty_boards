require "rails_helper"

# Dispatch coverage for issue #207 Phase 2: every user-lifecycle mailer must
# enqueue via ActiveJob (`deliver_later`) instead of blocking the request
# thread with `deliver_now`. We test one representative for each grouping
# rather than all 17 sites — the regression guard
# (spec/lib/no_inline_mailer_delivery_spec.rb) covers the rest.
RSpec.describe "User lifecycle mailers enqueue instead of delivering inline" do
  include ActiveJob::TestHelper

  let(:user) { FactoryBot.create(:user) }

  it "enqueues the welcome (free) email" do
    expect {
      user.send_welcome_email_free
    }.to have_enqueued_mail(UserMailer, :welcome_free_email).with(user)
  end

  it "enqueues the welcome (basic) email" do
    expect {
      user.send_welcome_email_basic
    }.to have_enqueued_mail(UserMailer, :welcome_basic_email).with(user)
  end

  it "enqueues the welcome (pro) email" do
    expect {
      user.send_welcome_email_pro
    }.to have_enqueued_mail(UserMailer, :welcome_pro_email).with(user)
  end

  it "enqueues the team invitation email from invite_to_team!" do
    inviter = FactoryBot.create(:user)
    team = FactoryBot.create(:team)
    # invite_to_team! also lazily provisions a Stripe customer; stub it so the
    # test stays focused on mailer dispatch and doesn't hit the real Stripe API.
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_#{SecureRandom.hex(4)}")
    expect {
      user.invite_to_team!(team, inviter, "member")
    }.to have_enqueued_mail(BaseMailer, :team_invitation_email)
  end

  it "enqueues the partner welcome email" do
    expect {
      user.send_partner_welcome_email
    }.to have_enqueued_mail(PartnerMailer, :welcome_email).with(user)
  end

  it "enqueues the pro setup email" do
    expect {
      user.send_pro_setup_email
    }.to have_enqueued_mail(SetupMailer, :pro_setup_email).with(user)
  end

  it "enqueues the vendor setup email" do
    expect {
      user.send_vendor_setup_email
    }.to have_enqueued_mail(SetupMailer, :vendor_setup_email).with(user)
  end

  it "enqueues the welcome-with-claim-link email" do
    expect {
      user.send_welcome_with_claim_link_email("some-slug")
    }.to have_enqueued_mail(UserMailer, :welcome_with_claim_link_email)
  end
end
