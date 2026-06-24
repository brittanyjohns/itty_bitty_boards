require "rails_helper"
require "rake"

RSpec.describe "settings rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["settings:cleanup"] }

  def run(env = {})
    env.each { |k, v| ENV[k] = v }
    task.reenable
    task.invoke
  ensure
    env.each_key { |k| ENV.delete(k) }
  end

  # Settings polluted by the old update_settings endpoint + the dead AI key.
  def dirty_settings
    {
      "wait_to_speak" => true,
      "board_limit" => 1,
      "controller" => "api/users",
      "action" => "update_settings",
      "id" => "5",
      "format" => "json",
      "user" => { "name" => "x" },
      "ai_monthly_limit" => 300,
    }
  end

  it "is a dry-run by default and changes nothing" do
    user = FactoryBot.create(:user)
    user.update_columns(settings: dirty_settings)

    run

    settings = user.reload.settings
    expect(settings).to have_key("controller")
    expect(settings).to have_key("ai_monthly_limit")
  end

  it "removes junk + dead keys when DRY_RUN=false, preserving real settings" do
    user = FactoryBot.create(:user)
    user.update_columns(settings: dirty_settings)

    run("DRY_RUN" => "false")

    settings = user.reload.settings
    %w[controller action id format user ai_monthly_limit].each do |junk|
      expect(settings).not_to have_key(junk)
    end
    # Real settings are untouched.
    expect(settings["wait_to_speak"]).to be(true)
    expect(settings["board_limit"]).to eq(1)
  end

  it "scopes to a single user with USER_ID" do
    target = FactoryBot.create(:user)
    bystander = FactoryBot.create(:user)
    target.update_columns(settings: dirty_settings)
    bystander.update_columns(settings: dirty_settings)

    run("DRY_RUN" => "false", "USER_ID" => target.id.to_s)

    expect(target.reload.settings).not_to have_key("controller")
    expect(bystander.reload.settings).to have_key("controller")
  end
end
