require "active_support/core_ext/integer/time"
Rails.application.routes.default_url_options[:host] = "speakanyway.com"
Rails.application.configure do
  config.log_file_size = 50.megabytes
  # ActiveRecord: only warn+
  config.active_record.logger = ActiveSupport::Logger.new($stdout)
  config.active_record.logger.level = Logger::WARN
  config.active_record.verbose_query_logs = false

  # ActiveStorage: only error+
  config.active_storage.logger = ActiveSupport::Logger.new($stdout)
  config.active_storage.logger.level = Logger::ERROR
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass

  # Do not fallback to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :amazon
  config.active_storage.content_types_to_serve_as_binary -= ["image/svg+xml", "image/svg"]
  config.active_storage.content_types_allowed_inline += ["image/svg+xml", "image/svg"]

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://app.speakanyway.com/cable"
  config.action_cable.url = "wss://670kd.hatchboxapp.com/cable"
  config.action_cable.allowed_request_origins = ["http://app.speakanyway.com", /https:\/\/.*\.speakanyway\.com/]
  config.action_cable.allowed_request_origins = [
    "https://app.speakanyway.com",  # your SPA/PWA
    "https://www.speakanyway.com",  # if you host the app there too
    "https://speakanyway.com",      # optional, only if app can run here
    "capacitor://localhost",         # Capacitor iOS/Android WebView origin
    "https://realtime-boards--speakanyway.netlify.app", # branch preview
  # If Android WebView ever presents as http://localhost, add it explicitly:
  # "http://localhost"
  ]

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Info include generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Use a different cache store in production.
  # config.cache_store = :mem_cache_store

  # Use a real queuing backend for Active Job (and separate queues per environment).
  # config.active_job.queue_adapter = :resque
  # config.active_job.queue_name_prefix = "itty_bitty_boards_production"

  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  config.action_mailer.raise_delivery_errors = true

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # SMTP Settings
  # Username: your e-mail address
  # Password: the password set in cPanel during the e-mail account set-up
  # Incoming server type: IMAP or POP3
  # Incoming server (IMAP): 993 port for SSL, 143 for TLS.
  # Incoming server (POP3): 995 port for SSL, 110 for TLS.
  # Outgoing server (SMTP): 465 port for SSL, 25/587 port for TLS.

#   config.action_mailer.delivery_method = :smtp
#   config.action_mailer.smtp_settings = {
#     address: "smtp.oxcs.bluehost.com",
#     port: 587,
#     user_name: ENV["SMTP_USERNAME"],
#     password: ENV["SMTP_PASSWORD"],
#     authentication: "plain",
#   }
# end

config.action_mailer.smtp_settings = {
    address: "smtp-relay.gmail.com",
    port: 587,
    domain: "speakanyway.com",
    enable_starttls_auto: true,
    # If you use IP-based authentication only (no username/password):
    authentication: nil,
  }