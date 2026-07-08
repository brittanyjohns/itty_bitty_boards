# Be sure to restart your server when you modify this file.
#
# This file eases your Rails 7.1 -> 7.2 upgrade. `config.load_defaults 7.2`
# (in config/application.rb) turns on ALL Rails 7.2 framework defaults. The
# overrides below are commented out, meaning the new 7.2 behavior is active.
# Uncomment an entry to revert that single default to its prior behavior if it
# causes a problem, then remove it once you've adopted the new behavior.
#
# Read the Rails 7.2 release notes / upgrade guide for the full details:
# https://guides.rubyonrails.org/upgrading_ruby_on_rails.html

###
# Controls whether Active Record will use decimal (bigdecimal) or float to
# decode PostgreSQL date/time columns. Rails 7.2 decodes dates as `Date`
# objects. Set to false to keep the pre-7.2 string decoding.
#++
# Rails.application.config.active_record.postgresql_adapter_decode_dates = false

###
# Enable validation of migration timestamps in development and test. A
# migration whose timestamp is more than a day in the future raises. Set to
# false to disable if you have legitimately future-dated migration files.
#++
# Rails.application.config.active_record.validate_migration_timestamps = false

###
# Controls the default headers Rails sends. Rails 7.2 drops the legacy
# `X-Download-Options` and `X-Permitted-Cross-Domain-Policies` headers.
# Uncomment to restore the pre-7.2 header set.
#++
# Rails.application.config.action_dispatch.default_headers = {
#   "X-Frame-Options" => "SAMEORIGIN",
#   "X-XSS-Protection" => "0",
#   "X-Content-Type-Options" => "nosniff",
#   "X-Download-Options" => "noopen",
#   "X-Permitted-Cross-Domain-Policies" => "none",
#   "Referrer-Policy" => "strict-origin-when-cross-origin"
# }
