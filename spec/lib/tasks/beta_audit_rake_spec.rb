require "rails_helper"
require "rake"
require "csv"

RSpec.describe "beta:audit_entitlements", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["beta:audit_entitlements"] }
  let(:csv_path) { Rails.root.join("tmp", "beta_audit_spec_#{Process.pid}.csv").to_s }

  after do
    task.reenable
    FileUtils.rm_f(csv_path)
  end

  def invoke_task
    ENV["BETA_AUDIT_CSV"] = csv_path
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    task.invoke
    output.string
  ensure
    $stdout = original_stdout
    ENV.delete("BETA_AUDIT_CSV")
  end

  def csv_rows
    CSV.read(csv_path, headers: true)
  end

  def row_for(user)
    csv_rows.find { |row| row["user_id"] == user.id.to_s }
  end

  # Beta-era shape: plan_type stayed "free" but Pro-level limits were written
  # into settings. Use update_columns so no callbacks rewrite the fixture.
  def give_pro_settings!(user)
    user.update_columns(settings: user.settings.merge(
      "board_limit" => User::PRO_PLAN_LIMITS["board_limit"],
      "paid_communicator_limit" => User::PRO_PLAN_LIMITS["paid_communicator_limit"],
    ))
    user
  end

  it "flags a free user with pro-level settings as over_settings" do
    user = give_pro_settings!(FactoryBot.create(:user, plan_type: "free"))

    output = invoke_task

    row = row_for(user)
    expect(row).to be_present
    expect(row["over_settings"]).to eq("true")
    expect(row["over_usage"]).to eq("false")
    expect(row["board_limit_setting"]).to eq(User::PRO_PLAN_LIMITS["board_limit"].to_s)
    expect(row["board_limit_entitled"]).to eq(User::FREE_PLAN_LIMITS["board_limit"].to_s)
    expect(row["exempt"]).to be_nil
    expect(output).to include("free=1")
  end

  it "flags a free user whose actual usage exceeds the free entitlement" do
    user = FactoryBot.create(:user, plan_type: "free")
    FactoryBot.create_list(:board, 2, user: user)
    FactoryBot.create_list(:child_account, 2, user: user, status: ChildAccount::ACTIVE)

    invoke_task

    row = row_for(user)
    expect(row).to be_present
    expect(row["over_usage"]).to eq("true")
    expect(row["board_count"]).to eq("2")
    expect(row["communicator_count"]).to eq("2")
  end

  it "does not list compliant users" do
    user = FactoryBot.create(:user, plan_type: "free")

    invoke_task

    expect(row_for(user)).to be_nil
  end

  it "audits paid users against their own plan's entitlement" do
    basic = FactoryBot.create(:user, plan_type: "basic")
    basic.update_columns(settings: basic.settings.merge(
      "board_limit" => User::PRO_PLAN_LIMITS["board_limit"],
    ))
    compliant_pro = FactoryBot.create(:user, plan_type: "pro")

    invoke_task

    row = row_for(basic)
    expect(row["over_settings"]).to eq("true")
    expect(row["board_limit_entitled"]).to eq(User::BASIC_PLAN_LIMITS["board_limit"].to_s)
    expect(row_for(compliant_pro)).to be_nil
  end

  it "respects a communicator_slot_limit settings override, matching enforcement" do
    user = FactoryBot.create(:user, plan_type: "free")
    user.update_columns(settings: user.settings.merge("communicator_slot_limit" => 5))

    invoke_task

    row = row_for(user)
    expect(row["over_settings"]).to eq("true")
    expect(row["communicator_limit_setting"]).to eq("5")
  end

  it "marks admin and partner accounts exempt and keeps them out of actionable counts" do
    admin = give_pro_settings!(FactoryBot.create(:user, plan_type: "free", role: "admin"))

    output = invoke_task

    expect(row_for(admin)["exempt"]).to eq("admin")
    expect(output).to include("Exempt (admin/partner_pro) flagged: 1")
    expect(output).to include("Over-entitled settings by plan: none")
  end

  it "excludes builder_child and predefined boards from the board count" do
    user = FactoryBot.create(:user, plan_type: "free")
    FactoryBot.create(:board, user: user)
    FactoryBot.create(:board, user: user, predefined: true)
    FactoryBot.create(:board, user: user, settings: { "builder_child" => true })

    invoke_task

    # 1 countable board == free limit, so not over and not in the CSV.
    expect(row_for(user)).to be_nil
  end

  it "performs no writes" do
    user = give_pro_settings!(FactoryBot.create(:user, plan_type: "free"))
    settings_before = user.reload.settings
    updated_at_before = user.updated_at

    invoke_task

    user.reload
    expect(user.settings).to eq(settings_before)
    expect(user.updated_at).to eq(updated_at_before)
  end

  it "prints a summary and the CSV path" do
    give_pro_settings!(FactoryBot.create(:user, plan_type: "free"))

    output = invoke_task

    expect(output).to include("Scanned")
    expect(output).to include("CSV: #{csv_path}")
    expect(output).to include("No writes performed.")
  end
end
