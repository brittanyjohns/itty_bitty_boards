require "rails_helper"

RSpec.describe AdminMailer, type: :mailer do
  describe "#disk_space_alert" do
    it "addresses the admin and renders a WARNING subject and body" do
      mail = described_class.disk_space_alert(usage: 85, severity: :warn).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("[WARNING] SpeakAnyWay server disk at 85%")
      expect((mail.html_part || mail).body.decoded).to include("85%")
      expect((mail.html_part || mail).body.decoded).to include("WARN")
    end

    it "uses a CRITICAL subject for critical severity" do
      mail = described_class.disk_space_alert(usage: 93, severity: :critical).deliver_now

      expect(mail.subject).to eq("[CRITICAL] SpeakAnyWay server disk at 93%")
      expect((mail.html_part || mail).body.decoded).to include("CRITICAL")
    end
  end

  describe "#new_clinician_application_email" do
    let(:applicant) { FactoryBot.create(:user, email: "at.coord@district.org") }

    def application(attrs = {})
      ClinicianApplication.create!(
        {
          user: applicant,
          status: ClinicianApplication::PENDING,
          full_name: "Alex Rivera",
          credential_type: "at_specialist",
          license_id: "AT-98765",
          workplace: "Riverside School District",
        }.merge(attrs),
      )
    end

    it "addresses the admin and names the applicant and credential in the subject" do
      mail = described_class.new_clinician_application_email(application).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Clinician application: Alex Rivera (AT Specialist)")
    end

    it "carries every field needed to triage without opening the dashboard" do
      mail = described_class.new_clinician_application_email(application).deliver_now
      body = (mail.html_part || mail).body.decoded

      expect(body).to include("Alex Rivera")
      expect(body).to include("at.coord@district.org")
      expect(body).to include("AT Specialist")
      expect(body).to include("AT-98765")
      expect(body).to include("Riverside School District")
    end

    it "links straight to the pending applications queue" do
      mail = described_class.new_clinician_application_email(application).deliver_now
      body = (mail.html_part || mail).body.decoded

      expect(body).to include("/admin/clinician_applications?status=pending")
    end

    it "renders an em dash for the optional fields the applicant left blank" do
      mail = described_class.new_clinician_application_email(
        application(license_id: nil, workplace: nil),
      ).deliver_now

      expect((mail.html_part || mail).body.decoded).to include("—")
    end
  end

  describe "#new_nomination_email" do
    # There is no admin UI for nominations yet, so this email is the only place
    # the details show up — every field has to survive into the body.
    def nomination(data = {})
      FactoryBot.create(
        :download_lead,
        email: "nominator@example.com",
        name: "Jane Doe",
        source: DownloadLead::NOMINATION_SOURCE,
        data: {
          "park" => "LaGrange Community Park",
          "city" => "LaGrange, OH",
          "role" => "Parent / caregiver",
          "why" => "Our son swings here every day and there are no words on the swings.",
          "sponsor_interest" => "No",
        }.merge(data),
      )
    end

    def body_of(mail)
      (mail.html_part || mail).body.decoded
    end

    it "addresses the admin, names the park in the subject, and renders the details" do
      mail = described_class.new_nomination_email(nomination).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Playground nomination: LaGrange Community Park (LaGrange, OH)")

      body = body_of(mail)
      expect(body).to include("LaGrange Community Park")
      expect(body).to include("nominator@example.com")
      expect(body).to include("Jane Doe")
      expect(body).to include("Parent / caregiver")
      expect(body).to include("there are no words on the swings")
    end

    it "calls out a nominator who is interested in sponsoring" do
      mail = described_class.new_nomination_email(nomination("sponsor_interest" => "Yes")).deliver_now
      expect(body_of(mail)).to include("interested in sponsoring")
    end

    it "does not call out sponsorship when they said no" do
      mail = described_class.new_nomination_email(nomination).deliver_now
      expect(body_of(mail)).not_to include("interested in sponsoring")
    end

    it "states plainly whether the nominator opted into marketing" do
      opted_out = body_of(described_class.new_nomination_email(nomination).deliver_now)
      expect(opted_out).to include("not added to any list")

      opted_in = body_of(
        described_class.new_nomination_email(nomination("marketing_opt_in" => true)).deliver_now,
      )
      expect(opted_in).to include("added to Mailchimp")
    end

    it "renders a sparse nomination without blowing up" do
      lead = FactoryBot.create(:download_lead, source: DownloadLead::NOMINATION_SOURCE, data: {})
      mail = described_class.new_nomination_email(lead).deliver_now

      expect(mail.subject).to eq("Playground nomination: Unnamed playground")
      expect(body_of(mail)).to include(lead.email)
    end
  end

  describe "#partner_pilot_review" do
    it "addresses the admin, summarizes counts, and lists both groups" do
      expiring = FactoryBot.create(:user, name: "Soon", email: "soon@example.com", plan_type: "partner_pro")
      expiring.update_columns(plan_expires_at: 5.days.from_now)
      expired = FactoryBot.create(:user, name: "Past", email: "past@example.com", plan_type: "partner_pro")
      expired.update_columns(plan_expires_at: 3.days.ago)

      mail = described_class.partner_pilot_review(expiring: [expiring], expired: [expired]).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Partner pilots: 1 ended, 1 ending soon")
      body = (mail.html_part || mail).body.decoded
      expect(body).to include("soon@example.com")
      expect(body).to include("past@example.com")
    end

    it "renders cleanly when a group is empty" do
      mail = described_class.partner_pilot_review(expiring: [], expired: []).deliver_now
      expect(mail.subject).to eq("Partner pilots: 0 ended, 0 ending soon")
      expect((mail.html_part || mail).body.decoded).to include("None.")
    end
  end

  describe "#new_user_email" do
    let(:user) do
      FactoryBot.create(:user, name: "Jane Doe", email: "jane@example.com", plan_type: "free").tap do |u|
        u.update_columns(stripe_customer_id: "cus_ABC123", current_sign_in_ip: "8.8.8.8")
        u.record_signup_context!(platform: "ios", method: "standard")
      end
    end

    before { allow(IpGeolocation).to receive(:coarse).and_return(nil) }

    it "puts the email, plan, and platform in the subject" do
      mail = described_class.new_user_email(user).deliver_now
      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("New signup: jane@example.com (free · ios)")
    end

    it "renders the signup context and omits the legacy tokens field" do
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("jane@example.com")
      expect(body).to include("standard")
      expect(body).to include("ios")
      expect(body).not_to match(/Tokens:/i)
    end

    it "links to the admin dashboard and the Stripe customer" do
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("/admin/users/#{user.id}")
      expect(body).to include("https://dashboard.stripe.com/customers/cus_ABC123")
    end

    it "omits the Stripe subscription link when there is no subscription" do
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).not_to include("dashboard.stripe.com/subscriptions")
    end

    it "includes the Stripe subscription link when there is one" do
      user.update_columns(stripe_subscription_id: "sub_XYZ789")
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("https://dashboard.stripe.com/subscriptions/sub_XYZ789")
    end

    it "renders a coarse location when the lookup succeeds" do
      allow(IpGeolocation).to receive(:coarse).with("8.8.8.8")
        .and_return({ city: "Austin", region: "Texas", country: "US", label: "Austin, Texas, US" })
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("Austin, Texas, US")
    end

    it "omits the location row when the lookup returns nil" do
      message = described_class.new_user_email(user).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).not_to match(/Location/i)
    end

    it "renders unknown for an account with no captured signup context" do
      legacy = FactoryBot.create(:user, email: "legacy@example.com")
      message = described_class.new_user_email(legacy).deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("unknown")
    end

    it "prefixes the subject on staging" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      expect(described_class.new_user_email(user).subject).to start_with("[STAGING] ")
    end
  end

  describe "#plan_change_email" do
    let(:user) do
      FactoryBot.create(:user, name: "Jane Doe", email: "jane@example.com", plan_type: "pro").tap do |u|
        u.update_columns(stripe_customer_id: "cus_ABC123", stripe_subscription_id: "sub_XYZ789", monthly_price: 19.99)
        u.settings["billing_interval"] = "month"
        u.save
      end
    end

    it "names both plans and the source in the subject" do
      mail = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe").deliver_now
      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Upgrade: jane@example.com free → pro (stripe)")
    end

    it "renders the plan transition, billing interval, and Stripe links" do
      message = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe")
        .deliver_now
      body = (message.html_part || message).body.decoded
      expect(body).to include("free")
      expect(body).to include("pro")
      expect(body).to include("month")
      expect(body).to include("https://dashboard.stripe.com/subscriptions/sub_XYZ789")
      expect(body).to include("/admin/users/#{user.id}")
    end

    it "prefixes the subject on staging" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      mail = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe")
      expect(mail.subject).to start_with("[STAGING] ")
    end
  end
end
