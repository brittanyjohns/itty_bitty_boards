# Be sure to restart your server when you modify this file.
#
# This file eases your Rails 7.2 -> 8.0 upgrade. `config.load_defaults 8.0`
# (in config/application.rb) turns on ALL Rails 8.0 framework defaults. The
# overrides below are commented out, meaning the new 8.0 behavior is active.
# Uncomment an entry to revert that single default to its prior behavior if it
# causes a problem, then remove it once you've adopted the new behavior.
#
# See the Rails 8.0 upgrade guide for full details:
# https://guides.rubyonrails.org/upgrading_ruby_on_rails.html

###
# Specifies whether `to_time` methods preserve the UTC offset of their
# receivers or preserves the timezone. Rails 8.0 preserves the timezone
# (`:zone`). Uncomment to keep the prior `:offset` behavior.
#++
# Rails.application.config.active_support.to_time_preserves_timezone = :offset

###
# Determines whether only ETags are considered for making a response fresh,
# ignoring the Last-Modified header, when both are present. Rails 8.0 uses the
# stricter matching (`true`). Uncomment to keep the prior lenient behavior.
#++
# Rails.application.config.action_dispatch.strict_freshness = false
