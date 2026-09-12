class ApplicationMailer < ActionMailer::Base
  default from: "noreply@speakanyway.com"
  layout "mailer"

  # The failure half of mail visibility (the success half is
  # MailDeliveryObserver). `deliver_now` — which is what MailDeliveryJob calls
  # for every `deliver_later` — wraps rendering AND transport in
  # `handle_exceptions`, so this catches an SMTP rejection, an auth failure and
  # a stalled connection alike, and tags them with one greppable prefix
  # (`bin/prod-logs worker | grep "\[mail\]"`). Without it a hard bounce was
  # only ever a generic Sidekiq retry line naming no recipient (#820).
  #
  # It re-raises: Sidekiq's retry/dead-set behaviour is the actual handling and
  # must not change. This adds a signal, it does not swallow a failure.
  #
  # The same failure is also written to `mail_deliveries` (#824) so it is
  # visible on the admin dashboard rather than only to whoever greps the box —
  # "we'll email you as soon as it's approved" is a promise an admin has to be
  # able to check.
  # A `deliver_later` failure reaches this handler TWICE, and only the first
  # pass is an instance. `MessageDelivery#deliver_now` calls the mailer
  # INSTANCE's `handle_exceptions` — that pass is what logs the line and writes
  # the `mail_deliveries` row — and then re-raises into `MailDeliveryJob`, whose
  # own `rescue_from` calls the CLASS-level `ActionMailer::Base.handle_exception`
  # and `instance_exec`s this same block with `self` set to the mailer CLASS,
  # where `action_name` and `message` do not exist. Reading them there raised
  # `NameError` from inside the handler, which REPLACED the original error on
  # its way out: every `deliver_later` failure reached Sidekiq's retry/dead set
  # as "undefined local variable or method `action_name'" instead of the SMTP
  # error, and the second pass logged nothing at all. Since this is the
  # environment-wide send path, that was every mail failure in production.
  # Re-raise on the class pass and let the instance pass — which has already
  # recorded the row — be the one that reports, so the row is written exactly
  # once and the transport's own error survives (#928, finding 2).
  rescue_from StandardError do |error|
    raise error if is_a?(Class)

    Rails.logger.error(
      "[mail] delivery_failed mailer=#{self.class.name}##{action_name} " \
      "to=#{Array(message&.to).join(",")} " \
      "error=#{error.class}: #{error.message}"
    )
    MailDelivery.record(
      status: MailDelivery::FAILED,
      message: message,
      mailer: "#{self.class.name}##{action_name}",
      error: error,
    )
    raise error
  end

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
