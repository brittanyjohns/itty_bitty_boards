require "rails_helper"
require "rake"

RSpec.describe "mailchimp:retry_failed_leads", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["mailchimp:retry_failed_leads"] }

  after do
    task.reenable
    ENV.delete("DRY_RUN")
    ENV.delete("EMAIL")
  end

  def invoke_task
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    task.invoke
    output.string
  ensure
    $stdout = original_stdout
  end

  let!(:failed_lead) do
    FactoryBot.create(:download_lead, email: "fail@example.com",
                                      mailchimp_status: DownloadLead::MAILCHIMP_FAILED)
  end
  let!(:synced_lead) do
    FactoryBot.create(:download_lead, email: "ok@example.com",
                                      mailchimp_status: DownloadLead::MAILCHIMP_SYNCED)
  end

  it "dry-runs by default: lists failed leads, enqueues nothing, no writes" do
    expect(MailchimpUpsertLeadJob).not_to receive(:perform_async)

    output = invoke_task

    expect(output).to include("Found 1 failed lead")
    expect(output).to include(failed_lead.email)
    expect(output).to include("Dry run")
    expect(failed_lead.reload.mailchimp_status).to eq(DownloadLead::MAILCHIMP_FAILED)
  end

  it "with DRY_RUN=false resets status to pending and enqueues the job for failed leads only" do
    ENV["DRY_RUN"] = "false"
    expect(MailchimpUpsertLeadJob).to receive(:perform_async).with(failed_lead.id).once
    expect(MailchimpUpsertLeadJob).not_to receive(:perform_async).with(synced_lead.id)

    invoke_task

    expect(failed_lead.reload.mailchimp_status).to eq(DownloadLead::MAILCHIMP_PENDING)
    expect(synced_lead.reload.mailchimp_status).to eq(DownloadLead::MAILCHIMP_SYNCED)
  end

  it "scopes to a single address with EMAIL" do
    other_failed = FactoryBot.create(:download_lead, email: "other@example.com",
                                                     mailchimp_status: DownloadLead::MAILCHIMP_FAILED)
    ENV["DRY_RUN"] = "false"
    ENV["EMAIL"] = failed_lead.email
    expect(MailchimpUpsertLeadJob).to receive(:perform_async).with(failed_lead.id).once
    expect(MailchimpUpsertLeadJob).not_to receive(:perform_async).with(other_failed.id)

    invoke_task

    expect(other_failed.reload.mailchimp_status).to eq(DownloadLead::MAILCHIMP_FAILED)
  end
end
