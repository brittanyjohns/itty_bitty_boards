# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 8 threads for minimum
# and maximum; this matches the default thread size of Active Record.
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 8 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count

# Cluster mode in production: multiple workers + worker_timeout for resilience.
# Set after the 2026-05-30 outage where puma in single mode silently wedged all
# 8 threads on hung outbound calls (likely SMTP / OpenAI without timeouts) and
# stopped serving requests for 38 minutes. With 2 workers, a single wedged worker
# only halves capacity instead of taking the site down entirely.
#
# WEB_CONCURRENCY=2 default fits a t3.medium (2 vCPU, 3.8 GiB RAM): current
# memory footprint ~165 MB single-mode, so 2 workers ≈ 350 MB — well within budget.
#
# worker_timeout 30 is a backstop for a Ruby-VM-level deadlock; it does NOT fire
# when worker threads are merely blocked on IO (the heartbeat thread keeps running
# while request threads block on socket recv). The real defense against IO wedges
# is explicit timeouts on outbound calls (SMTP, OpenAI, etc.) — see
# config/environments/production.rb smtp_settings and app/models/open_ai_client.rb.
if ENV["RAILS_ENV"] == "production"
  worker_count = Integer(ENV.fetch("WEB_CONCURRENCY", 2))
  workers worker_count
  worker_timeout 30
  preload_app!

  # In cluster mode with preload_app!, the master loads the app once and forks
  # workers. Forked workers must re-establish their own ActiveRecord connection
  # pool — otherwise they share the master's connection and corrupt it.
  on_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  end
end

# In development, prevent worker_timeout from interrupting debugger pauses.
worker_timeout 3600 if ENV.fetch("RAILS_ENV", "development") == "development"

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT") { 4000 }

# Specifies the `environment` that Puma will run in.
environment ENV.fetch("RAILS_ENV") { "development" }

# Specifies the `pidfile` that Puma will use.
pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart
