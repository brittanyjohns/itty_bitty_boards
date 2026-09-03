require "rails_helper"
require "rake"

RSpec.describe "mail rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["mail:test"] }

  after { task.reenable }

  # The task prints its diagnosis to stdout, which is the whole product here —
  # an operator reads it to decide whether the transport is the problem. Capture
  # rather than assert on side effects.
  def run_task(recipient = "inbox@example.com")
    output = StringIO.new
    original = $stdout
    $stdout = output
    task.invoke(recipient)
    output.string
  ensure
    $stdout = original
  end

  # The config block only reports SMTP details when SMTP is the transport, and
  # the test environment uses :test. Stub the transport to reach it, and stub
  # the send itself so nothing opens a socket.
  def pretend_smtp(settings)
    allow(ActionMailer::Base).to receive(:delivery_method).and_return(:smtp)
    allow(ActionMailer::Base).to receive(:smtp_settings).and_return(settings)
    allow_any_instance_of(Mail::Message).to receive(:deliver!)
  end

  describe "mail:test" do
    it "delivers a connectivity test email to the given recipient" do
      expect { task.invoke("inbox@example.com") }
        .to change { Mail::TestMailer.deliveries.size }.by(1)

      expect(Mail::TestMailer.deliveries.last.to).to include("inbox@example.com")
    end

    it "aborts when no recipient is provided" do
      expect { task.invoke }.to raise_error(SystemExit)
    end
  end

  # #820: intra-domain mail arrived while external mail vanished with no error.
  # The relay warning is the one signal that names that failure mode, so it has
  # to fire on the HOST actually in use — not on whether credentials happen to
  # be set, which is what let production's real configuration through silently.
  describe "mail:test relay warning" do
    it "warns when credentials are set but SMTP_ADDRESS forces the relay" do
      pretend_smtp(
        address: "smtp-relay.gmail.com",
        user_name: "noreply@speakanyway.com",
        password: "app-password",
      )

      output = run_task

      expect(output).to include("IP relay")
      expect(output).to include("SMTP_ADDRESS")
      expect(output).to include("Credentials ARE set")
    end

    it "warns, and says which credentials are missing, on the unauthenticated relay" do
      pretend_smtp(address: "smtp-relay.gmail.com")

      output = run_task

      expect(output).to include("IP relay")
      expect(output).to include("No SMTP_USERNAME/SMTP_PASSWORD is set")
    end

    it "stays quiet on authenticated submission" do
      pretend_smtp(
        address: "smtp.gmail.com",
        user_name: "noreply@speakanyway.com",
        password: "app-password",
      )

      expect(run_task).not_to include("IP relay")
    end
  end
end
