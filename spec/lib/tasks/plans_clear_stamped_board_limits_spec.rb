# frozen_string_literal: true

require "rails_helper"
require "rake"

# One-time cleanup for #796. `board_limit` used to be stamped into settings by
# the plan setters; now settings means "deliberate admin override", so every
# frozen copy has to go or those users never see a future plan/ENV change.
RSpec.describe "plans:clear_stamped_board_limits", type: :task do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:task) { Rake::Task["plans:clear_stamped_board_limits"] }

  def run_task(dry_run: false, extra: nil)
    ENV["DRY_RUN"] = dry_run.to_s
    ENV["EXTRA_STAMPED_VALUES"] = extra
    task.reenable
    buffer = StringIO.new
    original = $stdout
    $stdout = buffer
    begin
      task.invoke
    ensure
      $stdout = original
    end
    buffer.string
  ensure
    ENV.delete("DRY_RUN")
    ENV.delete("EXTRA_STAMPED_VALUES")
  end

  def stamped(plan_type, value)
    create(:user, plan_type: plan_type).tap do |u|
      u.update_columns(settings: (u.settings || {}).merge("board_limit" => value))
    end
  end

  it "clears a value the current plan constant would have stamped" do
    user = stamped("basic", User::BASIC_PLAN_LIMITS["board_limit"])

    run_task

    expect(user.reload.settings).not_to have_key("board_limit")
    expect(user.board_limit).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
  end

  it "clears a pre-#796 default even when the constant has since moved" do
    user = stamped("pro", 300) # the value the setter wrote before #796

    run_task

    expect(user.reload.settings).not_to have_key("board_limit")
  end

  it "keeps a value no setter could have written, and says so" do
    user = stamped("basic", 250)

    output = run_task

    expect(user.reload.settings["board_limit"]).to eq(250)
    expect(output).to match(/kept user=#{user.id}/)
    expect(output).to match(/kept_as_override=1/)
  end

  it "clears a kept-looking value when EXTRA_STAMPED_VALUES names it" do
    user = stamped("basic", 250)

    run_task(extra: "250")

    expect(user.reload.settings).not_to have_key("board_limit")
  end

  # A stranded paid user resolves to FREE at read time, so wiping their stamped
  # 300 would silently drop them to 1. Never touch an unknown plan_type.
  describe "admins" do
    def stamped_admin(plan_type, value)
      create(:admin_user).tap do |u|
        u.update_columns(
          plan_type: plan_type,
          settings: (u.settings || {}).merge("board_limit" => value),
        )
      end
    end

    # The case the production dry run could NOT reveal: the live admin's value
    # (3000) happened not to match Pro's 300, so it landed in `kept` by
    # coincidence rather than by rule. An admin stamped with the plan default
    # would have been cleared like any other row.
    it "never clears an admin whose value equals the plan default" do
      admin = stamped_admin("pro", User::PRO_PLAN_LIMITS["board_limit"])

      output = run_task

      expect(admin.reload.settings["board_limit"]).to eq(
        User::PRO_PLAN_LIMITS["board_limit"],
      )
      expect(output).to include("skipped admin user=#{admin.id}")
      expect(output).to include("skipped_admin=1")
    end

    it "never clears an admin holding a deliberate high override" do
      admin = stamped_admin("pro", 3000)

      run_task

      expect(admin.reload.settings["board_limit"]).to eq(3000)
    end

    it "counts an admin as skipped, not as a kept override" do
      stamped_admin("pro", User::PRO_PLAN_LIMITS["board_limit"])

      output = run_task

      expect(output).to include("skipped_admin=1")
      expect(output).to include("kept_as_override=0")
    end

    it "still clears non-admins in the same run" do
      admin = stamped_admin("pro", User::PRO_PLAN_LIMITS["board_limit"])
      ordinary = stamped("pro", User::PRO_PLAN_LIMITS["board_limit"])

      run_task

      expect(admin.reload.settings["board_limit"]).to be_present
      expect(ordinary.reload.settings).not_to have_key("board_limit")
    end
  end

  it "never touches a user with an unknown plan_type" do
    user = create(:user)
    user.update_columns(plan_type: "legacy_myspeak", settings: { "board_limit" => 300 })

    output = run_task

    expect(user.reload.settings["board_limit"]).to eq(300)
    expect(output).to match(/skipped_unknown_plan=1/)
  end

  it "writes nothing in DRY_RUN and says what it would do" do
    user = stamped("basic", User::BASIC_PLAN_LIMITS["board_limit"])

    output = run_task(dry_run: true)

    expect(user.reload.settings["board_limit"]).to be_present
    expect(output).to match(/would clear=1/)
    expect(output).to match(/DRY RUN/)
  end

  it "is idempotent" do
    user = stamped("pro", User::PRO_PLAN_LIMITS["board_limit"])
    run_task

    output = run_task

    expect(output).to match(/cleared=0/)
    expect(user.reload.settings).not_to have_key("board_limit")
  end
end
