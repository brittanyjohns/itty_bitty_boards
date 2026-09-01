namespace :mail do
  desc "Diagnose mail delivery: print the resolved ActionMailer config and send a test email. " \
       "Usage: bin/rails 'mail:test[you@example.com]'"
  task :test, [:to] => :environment do |_task, args|
    recipient = args[:to].presence || ENV["MAIL_TEST_TO"].presence
    if recipient.blank?
      abort "No recipient. Usage: bin/rails 'mail:test[you@example.com]'"
    end

    am = ActionMailer::Base
    settings = am.smtp_settings || {}

    puts "=" * 64
    puts "ActionMailer delivery diagnosis"
    puts "=" * 64
    puts "  Rails.env             : #{Rails.env}"
    puts "  STAGING               : #{ENV['STAGING'].inspect}"
    puts "  delivery_method       : #{am.delivery_method.inspect}"
    puts "  perform_deliveries    : #{am.perform_deliveries.inspect}"
    puts "  raise_delivery_errors : #{am.raise_delivery_errors.inspect}"
    if am.delivery_method == :smtp
      puts "  smtp.address          : #{settings[:address].inspect}"
      puts "  smtp.port             : #{settings[:port].inspect}"
      puts "  smtp.authentication   : #{settings[:authentication].inspect}"
      puts "  smtp.user_name        : #{settings[:user_name].present? ? '[set]' : '[blank]'}"
      puts "  smtp.password         : #{settings[:password].present? ? '[set]' : '[blank]'}"
    end
    unless am.perform_deliveries
      puts "  WARNING: perform_deliveries is false — the app sends no mail in this environment."
    end

    # The unauthenticated IP relay is the prime suspect whenever intra-domain
    # mail arrives and external mail vanishes with no error (#820): Google
    # Workspace's SMTP relay service applies its own per-recipient rules, and a
    # message it accepts and then drops leaves nothing behind in this app.
    # Authenticated submission via smtp.gmail.com does not depend on the
    # instance's outbound IP, which Hatchbox changes without warning.
    if am.delivery_method == :smtp && settings[:user_name].blank?
      puts "  WARNING: no SMTP_USERNAME/SMTP_PASSWORD — sending over the"
      puts "           unauthenticated #{settings[:address]} IP relay. External"
      puts "           recipients can be silently dropped by the relay's own"
      puts "           rules while intra-domain mail still arrives. Prefer"
      puts "           authenticated submission (set SMTP_USERNAME/SMTP_PASSWORD)."
    end
    puts "-" * 64
    puts "Sending connectivity test to #{recipient} ..."

    begin
      message = Mail.new
      message.from = "SpeakAnyWay <noreply@speakanyway.com>"
      message.to = recipient
      message.subject = "SpeakAnyWay mail test (#{Rails.env}) #{Time.current.iso8601}"
      message.body = "Plain-text connectivity check from #{Rails.env}. " \
                     "If this arrived, ActionMailer SMTP delivery is working."
      message.delivery_method(am.delivery_method, settings)
      message.deliver!
      puts "OK — handed off to the '#{am.delivery_method}' transport with no error."
      puts "Message-ID: #{message.message_id.inspect}"
      puts "If the message still doesn't arrive, check the spam folder, then"
      puts "look the Message-ID up in Google Admin > Reporting > Email Log"
      puts "Search — an accepted-then-dropped message is only visible there."
    rescue => e
      puts "FAILED — #{e.class}: #{e.message}"
      puts (e.backtrace || []).first(5).map { |line| "    #{line}" }.join("\n")
      abort "Mail delivery failed. Fix the error above (commonly SMTP credentials" \
            " or an unallowlisted sender IP), then re-run."
    end
  end
end
