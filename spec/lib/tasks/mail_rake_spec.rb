require "rails_helper"
require "rake"

RSpec.describe "mail rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["mail:test"] }

  after { task.reenable }

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
end
