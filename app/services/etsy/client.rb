# frozen_string_literal: true

require "faraday"
require "faraday/multipart"

# Thin REST client for Etsy's Open API v3, scoped to exactly what publishing a
# digital printable needs: create a listing, price it, attach gallery images,
# attach download files.
#
# Ported from speakanyway-printables `src/publishers/marketplaces/etsy-ops.ts`.
# Nearly every unusual line below encodes a live Etsy failure — the comments
# name them. Read them before changing a request shape.
#
# Unlike most clients in this app this one RAISES rather than returning a
# Result struct. A failed RevenueCat lookup degrades to "unverified" and the
# request continues; a failed Etsy call must abort the publish immediately and
# leave nothing half-created. Etsy::PublishBoardPrintable is the boundary that
# turns these into a Result for the UI.
module Etsy
  class Client
    API_BASE = "https://openapi.etsy.com/v3/application"
    OAUTH_TOKEN_URL = "https://api.etsy.com/v3/public/oauth/token"

    # Art & Collectibles > Prints > Digital Prints.
    #
    # Do NOT copy 6816 out of the printables repo's example config or
    # docs/etsy-cli-for-agents.md — both are stale. 6816 is not a node in
    # Etsy's taxonomy at all, and because Etsy accepts unknown ids without
    # complaint, every listing that pipeline produced silently landed under
    # "Bath & Beauty > … > Nail Tools > Dotting Tools" until it was caught.
    DEFAULT_TAXONOMY_ID = 2078

    TAXONOMY_CACHE_KEY = "etsy/seller_taxonomy_ids".freeze
    TAXONOMY_CACHE_TTL = 12.hours

    # Etsy caps a single download file at 20 MB.
    FILE_CAP_BYTES = 20 * 1024 * 1024

    TIMEOUT = 30
    OPEN_TIMEOUT = 10

    class Error < StandardError; end
    class ConfigurationError < Error; end

    def initialize(
      keystring: ENV["ETSY_KEYSTRING"],
      shared_secret: ENV["ETSY_SHARED_SECRET"],
      client_id: ENV["ETSY_OAUTH_CLIENT_ID"],
      shop_id: ENV["ETSY_SHOP_ID"]
    )
      @keystring = keystring
      @shared_secret = shared_secret
      @client_id = client_id
      @shop_id = shop_id
    end

    def self.configured? = new.configured?

    def configured?
      [@keystring, @shared_secret, @client_id, @shop_id].all?(&:present?) &&
        OauthCredential.for_provider(OauthCredential::PROVIDER_ETSY)&.refresh_token.present?
    end

    attr_reader :shop_id

    # Create a listing. Etsy always creates in `draft` state — going live is a
    # separate call this client deliberately does not implement. `state` is sent
    # explicitly anyway so the intent is visible in the request and assertable
    # in a spec.
    #
    # => { listing_id:, url: }
    def create_listing(title:, description:, price:, tags: [], taxonomy_id: DEFAULT_TAXONOMY_ID, quantity: 999)
      body = {
        "quantity" => quantity.to_s,
        "title" => title.to_s,
        "description" => description.to_s,
        "price" => format("%.2f", price),
        "who_made" => "i_did",
        "when_made" => "2020_2026",
        "taxonomy_id" => taxonomy_id.to_s,
        "type" => "download",
        "state" => "draft",
      }

      # Etsy expects ONE comma-separated `tags` value. Repeated `tags` params
      # are not merged — Etsy keeps only the last, silently dropping the rest.
      normalized = normalize_tags(tags)
      body["tags"] = normalized.join(",") if normalized.any?

      response = request(:post, "/shops/#{shop_id}/listings", body: body)
      parsed = parse_json(response, "create-listing")
      listing_id = parsed["listing_id"]
      raise Error, "Etsy create-listing response missing listing_id" if listing_id.blank?

      {
        listing_id: listing_id.to_i,
        url: parsed["url"].presence || "https://www.etsy.com/listing/#{listing_id}",
      }
    end

    # Price cannot be set through the listing create/PATCH payload in a way that
    # sticks — Etsy returns 200 and ignores it. The inventory endpoint is the
    # only writer, and it is a full replace, so the current inventory has to be
    # read and echoed back with the price swapped in.
    def set_listing_price(listing_id, price)
      inventory = parse_json(request(:get, "/listings/#{listing_id}/inventory"), "get-inventory")

      products = Array(inventory["products"]).map do |product|
        {
          "sku" => product["sku"].to_s,
          "property_values" => Array(product["property_values"]).map do |value|
            {
              "property_id" => value["property_id"],
              "value_ids" => value["value_ids"],
              "scale_id" => value["scale_id"],
              "values" => value["values"],
            }
          end,
          "offerings" => Array(product["offerings"]).map do |offering|
            {
              "price" => price.to_f,
              "quantity" => offering["quantity"],
              "is_enabled" => offering["is_enabled"],
            }
          end,
        }
      end

      if products.empty?
        raise Error, "Etsy listing #{listing_id} returned no inventory products; cannot set price."
      end

      payload = {
        "products" => products,
        "price_on_property" => Array(inventory["price_on_property"]),
        "quantity_on_property" => Array(inventory["quantity_on_property"]),
        "sku_on_property" => Array(inventory["sku_on_property"]),
      }

      request(
        :put,
        "/listings/#{listing_id}/inventory",
        body: payload.to_json,
        headers: { "Content-Type" => "application/json" },
      )
      true
    end

    def upload_image(listing_id, bytes:, filename:, rank: 1)
      body = {
        "image" => multipart_part(bytes, "image/png", normalize_filename(filename)),
        "rank" => rank.to_s,
      }
      request(:post, "/shops/#{shop_id}/listings/#{listing_id}/images", body: body)
      true
    end

    def upload_file(listing_id, bytes:, filename:, rank: 1, mime_type: "application/pdf")
      if bytes.bytesize > FILE_CAP_BYTES
        raise Error, "#{filename} is #{bytes.bytesize} bytes; Etsy caps a download file at 20 MB."
      end

      name = normalize_filename(filename)
      body = {
        "file" => multipart_part(bytes, mime_type, name),
        "name" => name,
        "rank" => rank.to_s,
      }
      request(:post, "/shops/#{shop_id}/listings/#{listing_id}/files", body: body)
      true
    end

    # Etsy does NOT validate taxonomy_id on create: it accepts an unknown id,
    # returns 200, and files the listing under an arbitrary category — invisible
    # in the response and fatal to discoverability. So it has to be checked here.
    #
    # A failure to FETCH the taxonomy is not fatal; a transient Etsy blip should
    # not block a publish. Only a definitively-unknown id raises.
    def assert_known_taxonomy!(taxonomy_id)
      ids = begin
        taxonomy_ids
      rescue => e
        Rails.logger.warn("[Etsy::Client] could not fetch seller taxonomy, skipping validation: #{e.message}")
        return true
      end

      return true if ids.include?(taxonomy_id.to_i)

      raise Error, "Etsy taxonomy_id #{taxonomy_id} is not a node in Etsy's seller taxonomy. " \
                   "Etsy would accept it and file the listing under an arbitrary category."
    end

    def taxonomy_ids
      cached = Rails.cache.read(TAXONOMY_CACHE_KEY)
      return cached.to_set if cached.present?

      parsed = parse_json(request(:get, "/seller-taxonomy/nodes"), "seller-taxonomy")
      ids = []
      walk = lambda do |node|
        ids << node["id"].to_i
        Array(node["children"]).each { |child| walk.call(child) }
      end
      Array(parsed["results"]).each { |root| walk.call(root) }

      Rails.cache.write(TAXONOMY_CACHE_KEY, ids, expires_in: TAXONOMY_CACHE_TTL)
      ids.to_set
    end

    # Etsy allows letters, numbers, spaces, hyphens and apostrophes in a tag,
    # max 20 characters, max 13 tags. Anything else is silently dropped by Etsy,
    # so it is dropped here where it can be seen.
    def normalize_tags(tags)
      Array(tags).filter_map { |t| CopyRules.normalize_tag(t) }.uniq.first(CopyRules::TAG_MAX)
    end

    # Etsy's download-file names must be 3–70 chars of [A-Za-z0-9._-].
    def normalize_filename(filename)
      base = File.basename(filename.to_s).gsub(/[^A-Za-z0-9._-]/, "-").gsub(/-{2,}/, "-")
      base = "file-#{base}" if base.length < 3
      base.length > 70 ? "#{base[0, 66 - File.extname(base).length]}#{File.extname(base)}" : base
    end

    private

    # The DB-held grant, refreshed on demand. See OauthCredential for why the
    # refresh token cannot live in ENV.
    def access_token
      credential = OauthCredential.for_provider(OauthCredential::PROVIDER_ETSY)
      if credential.nil? || credential.refresh_token.blank?
        raise ConfigurationError, "No Etsy OAuth credential stored. Run `rake etsy:seed_refresh_token`."
      end
      return credential.access_token if credential.access_token_valid?

      token = nil
      # Row lock so two Sidekiq workers can't exchange the same single-use
      # refresh token concurrently — the loser's exchange 403s AND its rotation
      # clobbers the winner's token, killing the whole chain.
      credential.with_lock do
        token = credential.access_token_valid? ? credential.access_token : exchange_refresh_token!(credential)
      end
      token
    end

    def exchange_refresh_token!(credential)
      response = oauth_connection.post(OAUTH_TOKEN_URL) do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = {
          "grant_type" => "refresh_token",
          "client_id" => @client_id.to_s,
          "refresh_token" => credential.refresh_token,
        }
      end

      unless response.status == 200
        raise Error, "Etsy OAuth token exchange #{response.status}: #{truncate_body(response.body)}"
      end

      parsed = JSON.parse(response.body.to_s)
      access = parsed["access_token"]
      rotated = parsed["refresh_token"]
      if access.blank? || rotated.blank?
        raise Error, "Etsy OAuth response missing tokens"
      end

      # Etsy rotates the refresh token on EVERY exchange and invalidates the old
      # one. Persisting the new value is not an optimization — skip it and the
      # next publish is permanently 403.
      credential.update!(
        access_token: access,
        refresh_token: rotated,
        access_token_expires_at: Time.current + parsed["expires_in"].to_i.clamp(60, 1.day.to_i),
      )
      access
    end

    def request(method, path, body: nil, headers: {})
      raise ConfigurationError, "Etsy is not configured (missing ETSY_* env)." unless credentials_present?

      response = connection.run_request(method, "#{API_BASE}#{path}", body, default_headers.merge(headers))
      return response if response.success?

      raise Error, "Etsy #{method.to_s.upcase} #{path} #{response.status}: #{truncate_body(response.body)}"
    end

    def credentials_present?
      [@keystring, @shared_secret, @client_id, @shop_id].all?(&:present?)
    end

    def default_headers
      {
        "Authorization" => "Bearer #{access_token}",
        # Must be "keystring:secret" since Etsy's 2026-02-09 enforcement — the
        # bare keystring 401s.
        "x-api-key" => "#{@keystring}:#{@shared_secret}",
      }
    end

    def parse_json(response, label)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      raise Error, "Etsy #{label} returned unparseable JSON: #{e.message}"
    end

    def multipart_part(bytes, content_type, filename)
      Faraday::Multipart::FilePart.new(StringIO.new(bytes), content_type, filename)
    end

    def truncate_body(body) = body.to_s.truncate(300)

    def connection
      @connection ||= Faraday.new do |f|
        f.request :multipart
        f.request :url_encoded
        f.options.timeout = TIMEOUT
        f.options.open_timeout = OPEN_TIMEOUT
      end
    end

    def oauth_connection
      @oauth_connection ||= Faraday.new do |f|
        f.request :url_encoded
        f.options.timeout = TIMEOUT
        f.options.open_timeout = OPEN_TIMEOUT
      end
    end
  end
end
