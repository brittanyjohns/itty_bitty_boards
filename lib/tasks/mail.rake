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
      puts "If the message still doesn't arrive, check the spam folder and the" \
           " provider's outbound logs/dashboard."
    rescue => e
      puts "FAILED — #{e.class}: #{e.message}"
      puts (e.backtrace || []).first(5).map { |line| "    #{line}" }.join("\n")
      abort "Mail delivery failed. Fix the error above (commonly SMTP credentials" \
            " or an unallowlisted sender IP), then re-run."
    end
  end
end
