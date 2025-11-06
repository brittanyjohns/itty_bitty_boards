# config/initializers/mailchimp.rb
require "MailchimpMarketing"

module MailchimpClient
  def self.client
    @client ||= begin
        c = MailchimpMarketing::Client.new
        c.set_config(
          api_key: ENV.fetch("MAILCHIMP_API_KEY"),
          server: ENV.fetch("MAILCHIMP_SERVER_PREFIX"),
        )
        c
      end
  end
end
