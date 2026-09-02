# frozen_string_literal: true

require "rails_helper"
require "rake"

# READ-ONLY reconciliation of what a user is CHARGED for against what /boards
# LISTS. The two used to be different scopes (issue #804), so a Free user could
# be refused "1/1 boards" with an empty boards page. The task keeps telling the
# truth after the fix — the `null board_type` bucket should now read zero.
RSpec.describe "boards:limit_audit", type: :task do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:task) { Rake::Task["boards:limit_audit"] }
  let(:user) { create(:free_user) }

  def run_task(user_id: nil, email: nil)
    ENV["USER_ID"] = user_id&.to_s
    ENV["EMAIL"] = email
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
    ENV.delete("USER_ID")
    ENV.delete("EMAIL")
  end

  it "aborts when given neither USER_ID nor EMAIL" do
    expect { run_task }.to raise_error(SystemExit)
  end

  it "aborts when the id matches no user" do
    expect { run_task(user_id: 0) }.to raise_error(SystemExit)
  end

  it "finds the user by email too" do
    create(:board, user: user, board_type: "static")

    expect(run_task(email: user.email)).to include("user ##{user.id}")
  end

  it "reports the plan numbers behind a refusal" do
    create(:board, user: user, board_type: "static")

    output = run_task(user_id: user.id)

    expect(output).to include("plan_type              free")
    expect(output).to include("countable_board_count  1")
    expect(output).to include("at_board_limit?        true")
  end

  # The regression the task exists to prove is gone: a NULL board_type board is
  # counted AND listed now, so it must not be marked hidden.
  it "no longer reports a NULL board_type board as hidden" do
    create(:board, user: user, name: "Null Type", board_type: nil)

    output = run_task(user_id: user.id)

    expect(output).to include("Null Type")
    expect(output).not_to include("null board_type")
    expect(output).to match(/hidden=0/)
  end

  it "flags a sub-page as hidden from main_boards, and still counts it" do
    page = create(:board, user: user, name: "Food", board_type: "static")
    page.update_column(:sub_board, true)

    output = run_task(user_id: user.id)

    expect(output).to match(/Food.*HIDDEN \(sub-page\)/)
    expect(output).to include("countable_board_count  1")
  end

  it "lists a published menu as exempt rather than counted" do
    create(:board, user: user, name: "Public Diner", board_type: "menu", published: true)

    output = run_task(user_id: user.id)

    expect(output).to include("EXEMPT")
    expect(output).to include("Public Diner")
    expect(output).to include("countable_board_count  0")
    expect(output).to match(/exempt_menus=1/)
  end
end
