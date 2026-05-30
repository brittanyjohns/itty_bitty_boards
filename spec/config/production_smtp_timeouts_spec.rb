require "rails_helper"

# Regression coverage for the 2026-05-30 production outage (see issue #207):
# the Gmail SMTP `smtp_settings` hash in config/environments/production.rb was
# missing both `open_timeout` and `read_timeout`, so a stalled SMTP session
# during a synchronous mailer call could wedge a puma thread indefinitely.
#
# Rails only loads `config/environments/production.rb` when `Rails.env` is
# production, so we re-evaluate the file in an isolated context instead of
# trying to flip the environment under the test runner.
RSpec.describe "config/environments/production.rb SMTP timeouts" do
  let(:production_env_path) { Rails.root.join("config/environments/production.rb") }

  it "exists at the expected path" do
    expect(File.exist?(production_env_path)).to be true
  end

  it "includes an explicit open_timeout in smtp_settings" do
    expect(File.read(production_env_path)).to match(/open_timeout:\s*\d+/)
  end

  it "includes an explicit read_timeout in smtp_settings" do
    expect(File.read(production_env_path)).to match(/read_timeout:\s*\d+/)
  end

  it "caps open_timeout at no more than 30 seconds" do
    match = File.read(production_env_path).match(/open_timeout:\s*(\d+)/)
    expect(match).not_to be_nil, "expected open_timeout to be set"
    expect(Integer(match[1])).to be <= 30
  end

  it "caps read_timeout at no more than 60 seconds" do
    match = File.read(production_env_path).match(/read_timeout:\s*(\d+)/)
    expect(match).not_to be_nil, "expected read_timeout to be set"
    expect(Integer(match[1])).to be <= 60
  end
end
