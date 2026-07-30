class ApplicationMailer < ActionMailer::Base
  default from: "noreply@speakanyway.com"
  layout "mailer"

  # File under public/ holding the small logo used in email headers.
  EMAIL_LOGO_FILENAME = "email-logo.png"

  # Last resort when no mailer/route host is configured, so the logo is never
  # emitted as a relative URL (which no mail client can resolve). Every
  # environment sets a host, so this only guards a misconfiguration — prefer
  # EMAIL_LOGO_URL to move the asset somewhere else on purpose.
  EMAIL_LOGO_FALLBACK_HOST = "https://app.speakanyway.com"

  # Templates reference the header logo as `@logo.url`. It resolves to an
  # absolute HTTPS URL, never an inline (cid) attachment: mail clients list
  # every attachment part in the attachment strip — including an inline one the
  # HTML already references — so attaching the logo made it look like a
  # downloadable file. Do not reintroduce `attachments.inline` for the logo.
  EmailLogo = Struct.new(:url)

  def initialize(*args)
    super
    logo
  end

  def logo
    @logo = EmailLogo.new(self.class.email_logo_url)
  end

  # Set EMAIL_LOGO_URL to serve the logo from a CDN or a friendlier domain;
  # otherwise it is served out of this app's public/ on the same host the
  # mailer already builds links against, so it resolves per environment.
  def self.email_logo_url
    ENV["EMAIL_LOGO_URL"].presence || "#{email_asset_host}/#{EMAIL_LOGO_FILENAME}"
  end

  def self.email_asset_host
    options = ActionMailer::Base.default_url_options.presence ||
      Rails.application.routes.default_url_options.presence || {}
    host = options[:host].presence
    return EMAIL_LOGO_FALLBACK_HOST if host.blank?

    host = host.chomp("/")
    host = "#{options[:protocol].presence || "https"}://#{host}" unless host.start_with?("http")
    port = options[:port].presence
    port && !host.match?(/:\d+\z/) ? "#{host}:#{port}" : host
  end
end
