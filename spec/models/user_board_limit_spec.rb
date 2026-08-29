# frozen_string_literal: true

require "rails_helper"

# Issue #796: `board_limit` resolves from `plan_type` at READ time. It used to be
# stamped into settings by the five plan setters, so every user who had ever
# changed plans carried a frozen copy and changing a constant (or an ENV
# override) reached nobody. `settings["board_limit"]` now means exactly one
# thing: a deliberate admin override.
RSpec.describe User, "#board_limit", type: :model do
  def user_on(plan_type)
    build(:user, plan_type: plan_type)
  end

  describe "plan resolution" do
    {
      "free" => :FREE_PLAN_LIMITS,
      "basic" => :BASIC_PLAN_LIMITS,
      "basic_yearly" => :BASIC_PLAN_LIMITS,
      "basic_trial" => :BASIC_PLAN_LIMITS,
      "basic_5yr" => :BASIC_PLAN_LIMITS,
      "pro" => :PRO_PLAN_LIMITS,
      "pro_yearly" => :PRO_PLAN_LIMITS,
      "pro_5yr" => :PRO_PLAN_LIMITS,
      "partner_pro" => :PRO_PLAN_LIMITS,
      "clinician" => :CLINICIAN_PLAN_LIMITS,
    }.each do |plan_type, const|
      it "resolves #{plan_type} from #{const}" do
        expect(user_on(plan_type).board_limit).to eq(User.const_get(const)["board_limit"])
      end
    end

    it "falls back to Free for an unknown plan_type" do
      expect(user_on("enterprise_moon_tier").board_limit)
        .to eq(User::FREE_PLAN_LIMITS["board_limit"])
    end

    it "falls back to Free for a blank plan_type" do
      user = build(:user)
      user.plan_type = nil
      expect(user.board_limit).to eq(User::FREE_PLAN_LIMITS["board_limit"])
    end

    it "follows a plan change with nothing stamped in settings" do
      user = create(:user)
      user.update!(plan_type: "basic")

      expect(user.settings).not_to have_key("board_limit")
      expect(User.find(user.id).board_limit).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
    end
  end

  describe "the settings override" do
    it "wins over the plan value" do
      user = build(:user, plan_type: "pro", settings: { "board_limit" => 7 })
      expect(user.board_limit).to eq(7)
    end

    # API::Admin::UsersController stored the param uncoerced, so a JSON string
    # landed in settings and `countable_board_count >= board_limit` raised
    # ArgumentError on every board create.
    it "coerces a String, so at_board_limit? can't raise" do
      user = create(:user, settings: { "board_limit" => "250" })

      expect(user.board_limit).to eq(250)
      expect { user.at_board_limit? }.not_to raise_error
    end

    it "survives settings being nil" do
      user = build(:user, plan_type: "basic")
      user.settings = nil
      expect(user.board_limit).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
    end

    it "ignores a blank override" do
      user = build(:user, plan_type: "basic", settings: { "board_limit" => "" })
      expect(user.board_limit).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
    end
  end

  describe "the plan setters" do
    %i[setup_free_limits setup_basic_limits setup_pro_limits
       setup_clinician_limits setup_partner_pro_plan].each do |setter|
      it "#{setter} writes the communicator keys but never stamps board_limit" do
        user = build(:user)
        user.send(setter)

        expect(user.settings).not_to have_key("board_limit")
        expect(user.settings["paid_communicator_limit"]).to be_present
      end
    end
  end

  describe ".plan_limits_for" do
    it "covers every plan_type the setters dispatch on" do
      expect(User::PLAN_LIMITS_BY_TYPE.keys).to include(
        "free", "basic", "basic_yearly", "basic_trial", "basic_5yr",
        "pro", "pro_yearly", "pro_5yr", "partner_pro", "clinician",
      )
    end

    it "returns Free for anything it doesn't know" do
      expect(User.plan_limits_for("nope")).to eq(User::FREE_PLAN_LIMITS)
      expect(User.plan_limits_for(nil)).to eq(User::FREE_PLAN_LIMITS)
    end
  end

  describe "the retired second cap" do
    it "no longer exists on the model or in the plan hashes" do
      user = build(:user)
      expect(user).not_to respond_to(:board_group_limit)
      expect(user).not_to respond_to(:at_board_group_limit?)
      expect(User::FREE_PLAN_LIMITS).not_to have_key("board_group_limit")
      expect(User::PRO_PLAN_LIMITS).not_to have_key("board_group_limit")
    end
  end
end
