# # Be sure to restart your server when you modify this file.

# # Avoid CORS issues when API is called from the frontend app.
# # Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# # Read more: https://github.com/cyu/rack-cors

# Staging host is ENV-driven (issue #393) so a Hatchbox app/subdomain change
# needs no code change; defaults to the legacy subdomain for safety.
staging_host = ENV.fetch("STAGING_HOST", "ypk9e.hatchboxapp.com")

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins("http://localhost:8100",
            "https://speakanyway.com",
            "https://www.speakanyway.com",
            "https://app.speakanyway.com",
            "http://app.speakanyway.com",
            "https://#{staging_host}",
            "capacitor://localhost",
            "https://localhost",
            "http://localhost",
            "ionic://localhost",
            "http://192.168.11.65:8100",
            %r{\Ahttps://([a-z0-9-]+--)?speakanyway\.netlify\.app\z})

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: [:Authorization],  # Keep existing exposed headers
      credentials: true          # Allow credentials if needed
  end
end
