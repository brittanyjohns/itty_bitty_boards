#!/usr/bin/env ruby
# frozen_string_literal: true

# Triggers a deploy on the Hatchbox staging app via API.
#
# Two strategies, in priority order:
#   1. If HATCHBOX_STAGING_DEPLOY_HOOK is set, POST to that URL (the per-app
#      deploy webhook from Hatchbox's deploy settings - always works).
#   2. Otherwise POST to the API endpoint
#      /api/v1/accounts/<acct>/apps/<app>/deploys with a bearer token.
#
# Required ENV (one of):
#   HATCHBOX_STAGING_DEPLOY_HOOK, or
#   HATCHBOX_API_TOKEN + HATCHBOX_ACCOUNT_ID + HATCHBOX_STAGING_APP_ID

require "net/http"
require "uri"

def post(uri, headers = {}, body = "{}")
  req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
  req.body = body
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
end

if (hook = ENV["HATCHBOX_STAGING_DEPLOY_HOOK"]) && !hook.empty?
  res = post(URI(hook))
  abort "Hatchbox deploy hook #{res.code}: #{res.body}" unless res.code.to_i.between?(200, 299)
  puts "Hatchbox deploy triggered via deploy hook"
  exit 0
end

token      = ENV.fetch("HATCHBOX_API_TOKEN")
account_id = ENV.fetch("HATCHBOX_ACCOUNT_ID")
app_id     = ENV.fetch("HATCHBOX_STAGING_APP_ID")

uri = URI("https://app.hatchbox.io/api/v1/accounts/#{account_id}/apps/#{app_id}/deploys")
res = post(uri, "Authorization" => "Bearer #{token}")

unless res.code.to_i.between?(200, 299)
  abort "Hatchbox deploy trigger #{res.code}: #{res.body}\n" \
        "If this endpoint doesn't exist on your Hatchbox plan, set " \
        "HATCHBOX_STAGING_DEPLOY_HOOK to the per-app deploy webhook URL instead."
end

puts "Hatchbox deploy triggered via API for app #{app_id}"
