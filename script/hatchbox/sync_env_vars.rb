#!/usr/bin/env ruby
# frozen_string_literal: true

# Pushes the staging env-var set to Hatchbox via the public API.
#
# Required ENV:
#   HATCHBOX_API_TOKEN      - bearer token (account-level personal access token)
#   HATCHBOX_ACCOUNT_ID     - numeric account id (e.g. 4328)
#   HATCHBOX_STAGING_APP_ID - numeric app id for the staging Hatchbox app
#
# Plus every name listed in staging_env_vars.yml — values supplied by the
# caller (typically the staging-sync-env GitHub Actions workflow).
#
# Usage:
#   ruby script/hatchbox/sync_env_vars.rb

require "net/http"
require "json"
require "uri"
require "yaml"

token      = ENV.fetch("HATCHBOX_API_TOKEN")
account_id = ENV.fetch("HATCHBOX_ACCOUNT_ID")
app_id     = ENV.fetch("HATCHBOX_STAGING_APP_ID")

manifest_path = File.expand_path("staging_env_vars.yml", __dir__)
manifest      = YAML.load_file(manifest_path)
names         = manifest.fetch("vars")

missing = names.select { |n| ENV[n].nil? || ENV[n].empty? }
unless missing.empty?
  abort "Missing required env vars (set via GitHub secrets and wire up in " \
        "staging-sync-env.yml):\n  #{missing.join("\n  ")}"
end

env_vars = names.map { |name| { name: name, value: ENV.fetch(name) } }

uri = URI("https://app.hatchbox.io/api/v1/accounts/#{account_id}/apps/#{app_id}/env_vars")
req = Net::HTTP::Put.new(
  uri,
  "Content-Type"  => "application/json",
  "Authorization" => "Bearer #{token}"
)
req.body = JSON.dump(env_vars: env_vars)

res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }

unless res.code.to_i.between?(200, 299)
  abort "Hatchbox API #{res.code}: #{res.body}"
end

puts "Synced #{env_vars.size} env vars to Hatchbox app #{app_id}"
