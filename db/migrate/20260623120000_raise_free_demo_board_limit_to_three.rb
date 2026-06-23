# Free users' demo/sandbox communicators were seeded with
# settings["demo_board_limit"] = 1. We've raised FREE_DEMO_BOARD_LIMIT to 3 to
# match DEMO_ACCOUNT_BOARD_LIMIT, so existing Free accounts that were capped
# below 3 should be lifted to 3 too — otherwise current Free families stay
# stuck at one board while new ones get three.
class RaiseFreeDemoBoardLimitToThree < ActiveRecord::Migration[7.1]
  FLOOR = 3

  def up
    # jsonb lets us target only the rows that carry a sub-floor cap.
    ChildAccount
      .where("(settings ->> 'demo_board_limit') IS NOT NULL")
      .where("(settings ->> 'demo_board_limit')::int < ?", FLOOR)
      .find_each do |account|
        account.settings["demo_board_limit"] = FLOOR
        account.save!(validate: false)
      end
  end

  def down
    # Not reversible: prior per-account caps (all 1 for Free) aren't recoverable
    # and lowering them again would just re-impose the limit we removed.
    raise ActiveRecord::IrreversibleMigration
  end
end
