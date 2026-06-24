require "active_support/core_ext/integer/time"

# Staging runs with RAILS_ENV=production + STAGING=true on its own EC2 box
# (issue #393). The staging host is ENV-driven so a future Hatchbox app/subdomain
# change needs no code change; defaults to the legacy subdomain for safety.
staging = ENV["STAGING"] == "true"
staging_host = ENV.fetch("STAGING_HOST", "ypk9e.hatchboxapp.com")
primary_host = staging ? staging_host : "speakanyway.com"

Rails.application.routes.default_url_options[:host] = primary_host
Rails.application.routes.default_url_options[:protocol] = "https"
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

  config.active_storage.variant_processor = :vips
  config.active_storage.track_variants = true

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  config.action_cable.url = staging ? "wss://#{staging_host}/cable" : "wss://670kd.hatchboxapp.com/cable"
  config.action_cable.allowed_request_origins = [
    "https://app.speakanyway.com",  # SPA/PWA
    "https://www.speakanyway.com",
    "https://speakanyway.com",
    "https://#{staging_host}", # staging
    /https:\/\/.*\.speakanyway\.com/,
    "capacitor://localhost",         # Capacitor iOS/Android WebView
    %r{\Ahttps://([a-z0-9-]+--)?speakanyway\.netlify\.app\z}, # Netlify previews + branch deploys
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
  config.active_job.queue_adapter = :sidekiq
  # config.active_job.queue_name_prefix = "itty_bitty_boards_production"

  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  config.action_mailer.raise_delivery_errors = true

  config.action_mailer.default_url_options = {
    host: staging ? staging_host : "670kd.hatchboxapp.com",
    protocol: "https",
  }

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

  # Mailer transport. Authenticated SMTP submission is preferred: unlike the
  # IP-allowlisted relay, it does not depend on the server's outbound IP, which
  # changes when Hatchbox replaces the instance. Set SMTP_USERNAME / SMTP_PASSWORD
  # on the server (a Google Workspace account plus an App Password).
  #
  # - With credentials present: authenticates against smtp.gmail.com.
  # - Without credentials: falls back to the smtp-relay.gmail.com IP relay,
  #   which requires the sender IP to be allowlisted in the Workspace admin
  #   console (Apps > Google Workspace > Gmail > Routing > SMTP relay service).
  #
  # SMTP_ADDRESS overrides the host — e.g. set it to smtp-relay.gmail.com to
  # use the relay endpoint *with* authentication, which permits sending from
  # any From address in the domain (no per-address "send mail as" alias).
  # Diagnose with: bin/rails 'mail:test[you@example.com]'
  config.action_mailer.delivery_method = :smtp
  smtp_username = ENV["SMTP_USERNAME"].presence
  smtp_password = ENV["SMTP_PASSWORD"].presence
  config.action_mailer.smtp_settings = {
    address: ENV["SMTP_ADDRESS"].presence || (smtp_username ? "smtp.gmail.com" : "smtp-relay.gmail.com"),
    port: 587,
    domain: "speakanyway.com",
    enable_starttls_auto: true,
    user_name: smtp_username,
    password: smtp_password,
    authentication: smtp_username ? :plain : nil,
    # Explicit timeouts so a stalled Gmail SMTP session can't wedge a puma thread
    # indefinitely. Without these, Net::SMTP uses generous defaults that contributed
    # to the 2026-05-30 outage where all 8 threads stalled for 38 minutes.
    open_timeout: 10,
    read_timeout: 20,
  }
end
