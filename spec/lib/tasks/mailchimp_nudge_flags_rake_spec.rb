require "rails_helper"
require "rake"

RSpec.describe "mailchimp:nudge_flags", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  after do
    Rake::Task["mailchimp:nudge_flags:clear"].reenable
    Rake::Task["mailchimp:nudge_flags:report"].reenable
    ENV.delete("DRY_RUN")
    ENV.delete("EMAIL")
  end

  def invoke(task_name, *args)
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    Rake::Task[task_name].invoke(*args)
    output.string
  ensure
    $stdout = original_stdout
  end

  let!(:flagged) do
    create(:user, email: "flagged@example.com").tap do |user|
      user.update!(settings: (user.settings || {}).merge("first_board_nudge_sent" => true))
    end
  end
  let!(:unflagged) { create(:user, email: "clean@example.com") }

  describe ":clear" do
    it "dry-runs by default — lists the user but changes nothing" do
      output = invoke("mailchimp:nudge_flags:clear", "first_board_nudge_sent")

      expect(output).to include("Found 1 user(s) flagged first_board_nudge_sent")
      expect(output).to include("[dry-run] would clear first_board_nudge_sent for user #{flagged.id}")
      expect(flagged.reload.settings["first_board_nudge_sent"]).to eq(true)
    end

    it "removes the flag key entirely with DRY_RUN=false" do
      ENV["DRY_RUN"] = "false"
      invoke("mailchimp:nudge_flags:clear", "first_board_nudge_sent")

      expect(flagged.reload.settings).not_to have_key("first_board_nudge_sent")
    end

    it "leaves users who never carried the flag alone" do
      ENV["DRY_RUN"] = "false"
      output = invoke("mailchimp:nudge_flags:clear", "first_board_nudge_sent")

      expect(output).not_to include(unflagged.email)
      expect(unflagged.reload.settings).not_to have_key("first_board_nudge_sent")
    end

    it "scopes to a single address with EMAIL=" do
      other = create(:user, email: "other@example.com")
      other.update!(settings: (other.settings || {}).merge("first_board_nudge_sent" => true))
      ENV["DRY_RUN"] = "false"
      ENV["EMAIL"] = flagged.email

      invoke("mailchimp:nudge_flags:clear", "first_board_nudge_sent")

      expect(flagged.reload.settings).not_to have_key("first_board_nudge_sent")
      expect(other.reload.settings["first_board_nudge_sent"]).to eq(true)
    end

    it "warns when the journey can't be delivered — clearing alone won't email anyone" do
      allow(MailchimpClient).to receive(:journey_deliverable?).with("first_board_nudge").and_return(false)

      expect(invoke("mailchimp:nudge_flags:clear", "first_board_nudge_sent"))
        .to include("WARNING: journey 'first_board_nudge' is not deliverable")
    end

    it "refuses an unrecognized flag rather than touching anything" do
      expect { invoke("mailchimp:nudge_flags:clear", "not_a_flag") }
        .to raise_error(SystemExit)
      expect(flagged.reload.settings["first_board_nudge_sent"]).to eq(true)
    end
  end

  describe ":report" do
    it "counts flagged users per flag and names the blocked job when undeliverable" do
      allow(MailchimpClient).to receive(:journey_deliverable?).and_return(false)

      output = invoke("mailchimp:nudge_flags:report")

      expect(output).to match(/first_board_nudge_sent\s+1 flagged/)
      expect(output).to include("permanently excluded from MailchimpFirstBoardNudgeJob")
      expect(output).to match(/win_back_nudge_sent\s+0 flagged/)
    end
  end
end
