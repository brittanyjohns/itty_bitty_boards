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

    # The IP relay is the prime suspect whenever intra-domain mail arrives and
    # external mail vanishes with no error (#820): Google Workspace's SMTP relay
    # service applies its own per-recipient rules, and a message it accepts and
    # then drops leaves nothing behind in this app. Authenticated submission via
    # smtp.gmail.com does not depend on the instance's outbound IP, which
    # Hatchbox changes without warning.
    #
    # The question is which HOST the message actually leaves by, NOT whether
    # credentials exist. Asking `settings[:user_name].blank?` kept this silent
    # in exactly the configuration production turned out to be in: SMTP_USERNAME
    # *and* SMTP_ADDRESS both set, the latter pinning the relay — so
    # `ENV["SMTP_ADDRESS"].presence ||` in production.rb wins and the
    # authenticated-submission branch beside it is dead code. Credentials being
    # present is what made that read as healthy while the relay's own recipient
    # rules still governed every external send.
    if am.delivery_method == :smtp && settings[:address].to_s.include?("smtp-relay")
      puts "  WARNING: sending over the #{settings[:address]} IP relay. External"
      puts "           recipients can be silently dropped by the relay's own"
      puts "           rules while intra-domain mail still arrives."
      if settings[:user_name].blank?
        puts "           No SMTP_USERNAME/SMTP_PASSWORD is set — set both to"
        puts "           use authenticated submission instead."
      else
        puts "           Credentials ARE set, so this host is forced by"
        puts "           SMTP_ADDRESS=#{ENV["SMTP_ADDRESS"].inspect}. Clear it to"
        puts "           fall through to smtp.gmail.com (production.rb)."
      end
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
