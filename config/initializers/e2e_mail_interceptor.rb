# Drops outbound mail addressed to e2e test accounts.
#
# The frontend's Playwright suite (itty-bitty-frontend #620) creates throwaway
# accounts as e2e+<run-id>-<n>@speakanyway.com on STAGING. The speakanyway.com
# domain forwards unknown addresses to a real inbox, so every test run was
# flooding it with confirmation emails. Nobody legitimately uses this address
# pattern, so the interceptor is registered in every environment — pattern-
# scoped, not env-scoped — which also covers the (guarded-against) case of a
# suite pointed at the wrong host.
#
# Mail with a mix of recipients keeps its real ones and just sheds the e2e
# addresses; mail addressed only to e2e accounts is discarded outright.
class E2eMailInterceptor
  E2E_RECIPIENT = /\Ae2e\+[^@\s]*@speakanyway\.com\z/i

  def self.delivering_email(message)
    real = Array(message.to).reject { |addr| addr.match?(E2E_RECIPIENT) }
    if real.empty?
      message.perform_deliveries = false
      Rails.logger.info("[E2eMailInterceptor] dropped mail to #{Array(message.to).join(", ")}")
    elsif real.length != Array(message.to).length
      message.to = real
    end
  end
end

ActionMailer::Base.register_interceptor(E2eMailInterceptor)
