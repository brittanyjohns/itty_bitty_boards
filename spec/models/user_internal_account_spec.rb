require "rails_helper"

# demo_user? (gates Mailchimp journey sends) and the demo_accounts scope
# (drives admin/Mission Control metrics) are two expressions of one concept.
# If they disagree, the dashboards and the emails disagree about who is real —
# so every case here is asserted against BOTH.
RSpec.describe "internal/demo account identification" do
  def expect_treated_as_internal(user, internal:)
    expect(user.demo_user?).to eq(internal)
    expect(User.demo_accounts.exists?(user.id)).to eq(internal)
    expect(User.non_demo.exists?(user.id)).to eq(!internal)
  end

  describe "email patterns" do
    it "treats a bhannajohns+ alias as internal" do
      expect_treated_as_internal(create(:user, email: "bhannajohns+demo@gmail.com"), internal: true)
    end

    it "treats an @speakanyway.com address as internal" do
      expect_treated_as_internal(create(:user, email: "someone@speakanyway.com"), internal: true)
    end

    it "treats an ordinary customer as real" do
      expect_treated_as_internal(create(:user, email: "parent@example.com"), internal: false)
    end

    it "matches case-insensitively" do
      expect_treated_as_internal(create(:user, email: "Someone@SpeakAnyWay.com"), internal: true)
    end

    it "picks up extra patterns from DEMO_EMAIL_PATTERNS" do
      user = create(:user, email: "qa-bot@example.org")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("DEMO_EMAIL_PATTERNS").and_return("qa-bot@,loadtest+")

      expect_treated_as_internal(user, internal: true)
    end
  end

  # The gap that motivated the flag: a real testing session produced
  # speakanyway@gmail.com / testaria@gmail.com / speak@test.com, none of which
  # match a pattern, and they consumed journey sends and bounced.
  describe "the explicit internal_account flag" do
    it "treats a flagged account as internal even with an ordinary-looking email" do
      user = create(:user, email: "speakanyway@gmail.com")
      expect(user.demo_user?).to be false

      user.mark_internal!
      expect_treated_as_internal(user.reload, internal: true)
    end

    it "is reversible" do
      user = create(:user, email: "testaria@gmail.com")
      user.mark_internal!
      user.unmark_internal!

      expect_treated_as_internal(user.reload, internal: false)
      expect(user.settings).not_to have_key("internal_account")
    end

    it "preserves other settings keys when marking" do
      user = create(:user)
      user.update!(settings: (user.settings || {}).merge("first_board_nudge_sent" => true))

      user.mark_internal!

      expect(user.reload.settings["first_board_nudge_sent"]).to eq(true)
      expect(user.settings["internal_account"]).to eq(true)
    end

    # Mission Control joins boards onto this scope, and boards has its own
    # `settings` column — an unqualified reference makes the query ambiguous.
    it "survives being joined to a table that also has a settings column" do
      user = create(:user, email: "speakanyway@gmail.com")
      user.mark_internal!
      create(:board, user: user)

      expect {
        User.demo_accounts.left_joins(:boards)
          .select("users.id, COUNT(boards.id) AS boards_count")
          .group("users.id").to_a
      }.not_to raise_error
    end

    it "keeps admins out of demo_accounts, matching the previous scope" do
      admin = create(:admin_user, email: "boss@speakanyway.com")

      expect(User.demo_accounts.exists?(admin.id)).to be false
    end
  end

  describe "Mailchimp journey gating" do
    it "stops a flagged account from receiving a journey trigger" do
      user = create(:user, email: "speak@test.com")
      user.mark_internal!
      mailchimp = instance_double(MailchimpService)
      allow(MailchimpService).to receive(:new).and_return(mailchimp)
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      allow(MailchimpClient).to receive(:journey).and_return(journey_id: 10, step_id: 20)

      expect(mailchimp).not_to receive(:trigger_journey)

      MailchimpEventJob.new.perform(user.id, "journey", { "journey_key" => "first_board_nudge" })
    end
  end
end
