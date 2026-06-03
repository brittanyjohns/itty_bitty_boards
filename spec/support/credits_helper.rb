# Test helper for the AI credit ledger.
#
# New users land on `free` and get an automatic plan-credit grant
# from User#after_create. Specs that test credit-related behavior in
# isolation usually want to start from a clean ledger, so they can set
# up the exact balance they want to exercise. This helper does that.
module CreditsTestHelper
  def reset_user_credits!(user)
    user.credit_transactions.destroy_all
    user.update_columns(
      plan_credits_balance: 0,
      topup_credits_balance: 0,
      plan_credits_reset_at: nil,
    )
    user
  end
end

RSpec.configure do |config|
  config.include CreditsTestHelper
end
