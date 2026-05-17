Rails.application.configure do
  config.lograge.enabled = true

  # Drop the catch-all 404 controller from request logs. Vulnerability
  # scanners probe for /.env, /phpinfo.php, /.git/config, /wp-admin/…
  # constantly and there's no signal in those lines. ErrorController is
  # the sink for the `match "*path"` catch-all in config/routes.rb, so
  # this also hides 404s from real users mistyping URLs — acceptable.
  config.lograge.ignore_actions = ["ErrorController#not_found"]
end
