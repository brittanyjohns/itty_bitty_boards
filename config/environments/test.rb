require "active_support/core_ext/integer/time"

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!
Rails.application.routes.default_url_options[:host] = "localhost:4000"

Rails.application.configure do
  config.log_file_size = 50.megabytes

  # Debug-level logging writes every SQL statement to log/test.log — the suite
  # filled the 50 MB cap above in about two minutes of running, for output
  # nobody reads. Set VERBOSE_TEST_LOG=1 to get it back when debugging a spec.
  config.log_level = ENV["VERBOSE_TEST_LOG"].present? ? :debug : :warn

  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Off by default: no spec asserts on a statically-served file, so this only
  # added a middleware to every request. Re-enable if a spec ever needs to GET
  # something out of public/.
  config.public_file_server.enabled = ENV["TEST_PUBLIC_FILE_SERVER"].present?
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{1.hour.to_i}",
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Queue ActiveJob jobs but don't execute them. The default `:async` adapter
  # runs jobs on a thread pool, which means ActiveStorage::AnalyzeJob fires
  # after `attach` and shells out to `ffprobe` / `mediainfo` — fine locally
  # where those binaries exist, but hangs on CI runners that don't have
  # them. The test process then can't exit because the async pool waits on
  # the stuck thread. `:test` adapter queues without executing.
  config.active_job.queue_adapter = :test

  config.action_mailer.perform_caching = false

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true
end
