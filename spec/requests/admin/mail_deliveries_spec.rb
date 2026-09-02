# frozen_string_literal: true

require "rails_helper"

# #824 finding 2: a failed send has to be visible to an admin, not only to
# whoever can grep the box. "We'll email you as soon as it's approved" is
# promised twice on the clinician apply page.
RSpec.describe "Admin mail deliveries", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  def record(status, **attrs)
    MailDelivery.create!({ status: status }.merge(attrs))
  end

  # Required in every admin request spec — the layout calls the asset helpers.
  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    sign_in admin
  end

  it "lists the most recent sends with their Message-IDs" do
    record(MailDelivery::DELIVERED, recipients: "dana@gmail.com", subject: "Approved",
                                    message_id: "<abc123@speakanyway.com>")

    get admin_dashboard_mail_deliveries_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dana@gmail.com")
    expect(response.body).to include("&lt;abc123@speakanyway.com&gt;")
  end

  it "shows the error on a failed send" do
    record(MailDelivery::FAILED, recipients: "dana@gmail.com", mailer: "ClinicianMailer#approved",
                                 error_class: "Net::SMTPFatalError", error_message: "550 rejected")

    get admin_dashboard_mail_deliveries_path(status: MailDelivery::FAILED)

    expect(response.body).to include("Net::SMTPFatalError", "550 rejected", "ClinicianMailer#approved")
  end

  it "filters by status" do
    record(MailDelivery::DELIVERED, recipients: "delivered@example.com")
    record(MailDelivery::SUPPRESSED, recipients: "suppressed@example.com", reason: "staging")

    get admin_dashboard_mail_deliveries_path(status: MailDelivery::SUPPRESSED)

    expect(response.body).to include("suppressed@example.com")
    expect(response.body).not_to include("delivered@example.com")
  end

  it "searches by recipient — the shape of the real question" do
    record(MailDelivery::DELIVERED, recipients: "bhannajohns+dana@gmail.com", subject: "Welcome")
    record(MailDelivery::DELIVERED, recipients: "someone-else@gmail.com", subject: "Welcome")

    get admin_dashboard_mail_deliveries_path(q: "+dana@")

    expect(response.body).to include("bhannajohns+dana@gmail.com")
    expect(response.body).not_to include("someone-else@gmail.com")
  end

  it "refuses a non-admin" do
    sign_out admin
    sign_in create(:user)

    get admin_dashboard_mail_deliveries_path

    expect(response).to redirect_to(root_path)
  end
end
