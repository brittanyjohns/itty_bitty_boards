namespace :etsy do
  desc "Store this app's Etsy OAuth refresh token (rake 'etsy:seed_refresh_token[TOKEN]')"
  task :seed_refresh_token, [:token] => :environment do |_t, args|
    token = args[:token].presence || ENV["ETSY_OAUTH_REFRESH_TOKEN"].presence

    if token.blank?
      abort <<~MSG
        Usage: rake 'etsy:seed_refresh_token[<refresh-token>]'

        The token must come from a SEPARATE Etsy authorization, minted just for
        this app. Do NOT paste the one in speakanyway-printables/.env.

        Etsy rotates the refresh token on every exchange and invalidates the old
        one, so two systems sharing a single grant knock each other offline.
        Mint an independent one by running the printables repo's bootstrap again:

          cd ../speakanyway-printables
          npx tsx scripts/bootstrap-etsy-oauth.ts

        then pass the refresh token it prints to this task.
      MSG
    end

    credential = OauthCredential.upsert_refresh_token!(
      provider: OauthCredential::PROVIDER_ETSY,
      refresh_token: token,
      metadata: { "seeded_at" => Time.current.iso8601, "shop_id" => ENV["ETSY_SHOP_ID"] },
    )

    puts "Stored Etsy refresh token (credential ##{credential.id})."
    puts "Missing env: #{missing_etsy_env.join(', ')}" if missing_etsy_env.any?
  end

  desc "Show whether Etsy publishing is configured, without printing any secrets"
  task status: :environment do
    credential = OauthCredential.for_provider(OauthCredential::PROVIDER_ETSY)

    puts "ETSY_SHOP_ID:       #{ENV['ETSY_SHOP_ID'].presence || '(unset)'}"
    puts "Missing env:        #{missing_etsy_env.presence&.join(', ') || 'none'}"
    puts "Refresh token:      #{credential&.refresh_token.present? ? 'stored' : 'MISSING'}"
    puts "Access token:       #{credential&.access_token_valid? ? "cached until #{credential.access_token_expires_at}" : 'will refresh on next call'}"
    puts "Configured:         #{Etsy::Client.configured?}"
  end

  def missing_etsy_env
    %w[ETSY_KEYSTRING ETSY_SHARED_SECRET ETSY_OAUTH_CLIENT_ID ETSY_SHOP_ID].reject { |k| ENV[k].present? }
  end
end
