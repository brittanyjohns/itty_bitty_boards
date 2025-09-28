require "active_support/core_ext/integer/time"
require "logger"

Rails.application.routes.default_url_options[:host] = "localhost:4000"
ActiveRecord.verbose_query_logs = false
Rails.application.configure do
  logger = ActiveSupport::Logger.new("log/#{Rails.env}.log")
  logger.formatter = config.log_formatter
  config.logger = ActiveSupport::TaggedLogging.new(logger)
  config.log_level = :debug
  config.log_file_size = 50.megabytes

  # ActiveRecord: only warn+
  config.active_record.logger = ActiveSupport::Logger.new($stdout)
  config.active_record.logger.level = Logger::DEBUG
  config.active_record.verbose_query_logs = false

  # ActiveStorage: only error+
  config.active_storage.logger = ActiveSupport::Logger.new($stdout)
  config.active_storage.logger.level = Logger::DEBUG

  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}",
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  config.action_controller.default_url_options = { host: "http://localhost:4000" }
  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = ENV["ACTIVE_STORAGE_SERVICE"] || :amazon
  config.active_storage.content_types_to_serve_as_binary -= ["image/svg+xml", "image/svg"]
  config.active_storage.content_types_allowed_inline += ["image/svg+xml", "image/svg"]
  # Don't care if the mailer can't send.
  # config.action_mailer.raise_delivery_errors = false
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true

  # SMTP Settings
  # Username: your e-mail address
  # Password: the password set in cPanel during the e-mail account set-up
  # Incoming server type: IMAP or POP3
  # Incoming server (IMAP): 993 port for SSL, 143 for TLS.
  # Incoming server (POP3): 995 port for SSL, 110 for TLS.
  # Outgoing server (SMTP): 465 port for SSL, 25/587 port for TLS.

  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: "smtp.oxcs.bluehost.com",
    port: 587,
    user_name: ENV["SMTP_USERNAME"],
    password: ENV["SMTP_PASSWORD"],
    authentication: "plain",
  }
  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Suppress logger output for asset requests.
  # config.assets.quiet = true
  config.assets.debug = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true
  config.action_cable.allowed_request_origins = ["http://localhost:4000", /http:\/\/127\.0\.0\.1:\d+/]

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true
end
