# This file is copied to spec/ when you run 'rails generate rspec:install'
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
# Prevent database truncation if the environment is running in production mode!
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "sidekiq/testing"
Sidekiq::Testing.fake!
require "test_prof/recipes/rspec/let_it_be"
require "test_prof/recipes/rspec/before_all"
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)

Rails.root.glob("spec/support/**/*.rb").sort.each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

module AuthHelpers
  def auth_headers(user)
    { "Authorization" => "Bearer #{user.authentication_token}" }
  end
end

RSpec.configure do |config|
  config.fixture_paths = [
    Rails.root.join("spec/fixtures"),
  ]

  config.use_transactional_fixtures = true

  config.include FactoryBot::Syntax::Methods
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include AuthHelpers, type: :request
  config.include ActiveSupport::Testing::TimeHelpers

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Active Storage URL helpers need this set per-request in production; tests
  # never run a real request cycle so we set it once globally.
  config.before(:each) do
    ActiveStorage::Current.url_options = { host: "localhost", port: 4000, protocol: "http" }

    # Keep the users id sequence above User::DEFAULT_ADMIN_ID. Several specs
    # insert the admin with an explicit id (== DEFAULT_ADMIN_ID); an explicit
    # id doesn't advance the Postgres sequence, and sequences aren't rolled back
    # between examples — so depending on shard/run order, a later create(:user)
    # could grab that same id and raise PG::UniqueViolation on users_pkey. This
    # makes the next sequence id deterministically clear of the fixed admin id.
    ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT setval(
        pg_get_serial_sequence('users', 'id'),
        GREATEST(COALESCE((SELECT MAX(id) FROM users), 0), #{User::DEFAULT_ADMIN_ID}),
        true
      )
    SQL
  end
end
