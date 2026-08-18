require "rails_helper"
require "rake"

# Repairs boards whose Menu parent was severed by the old unconditional
# reassignment in BoardsController#update. The board row keeps no other pointer
# to its Menu, so the only handle left is owner + name — which is safe because
# menus_controller#create names the board after the menu.
RSpec.describe "menu_boards:relink" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("menu_boards:relink")
  end

  let(:task) { Rake::Task["menu_boards:relink"] }
  let(:user) { create(:user) }

  before { task.reenable }
  after do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  def severed_board(name, **attrs)
    create(:board, user: user, name: name, board_type: "menu",
                   parent_type: "User", parent_id: user.id, **attrs)
  end

  it "reports without writing by default" do
    menu = create(:menu, user: user, name: "Applebees")
    board = severed_board("Applebees")

    expect { task.invoke }.to output(/would re-link 1 board/).to_stdout

    expect(board.reload.parent_type).to eq("User")
    expect(menu.reload.boards).to be_empty
  end

  it "re-links a board to the one Menu of the same name with DRY_RUN=false" do
    menu = create(:menu, user: user, name: "Applebees")
    board = severed_board("Applebees")

    ENV["DRY_RUN"] = "false"
    expect { task.invoke }.to output(/re-linked 1 board/).to_stdout

    board.reload
    expect(board.parent_type).to eq("Menu")
    expect(board.parent_id).to eq(menu.id)
  end

  it "leaves a board with no matching Menu alone" do
    board = severed_board("Orphan Diner")

    ENV["DRY_RUN"] = "false"
    expect { task.invoke }.to output(/1 board\(s\) with no Menu of the same name/).to_stdout

    expect(board.reload.parent_type).to eq("User")
  end

  # Re-parenting onto the wrong Menu would show a stranger's menu photo, which
  # is worse than the missing button — so an unresolvable tie is left for a human.
  it "leaves an ambiguous match alone when the menus are far apart in time" do
    create(:menu, user: user, name: "Applebees", created_at: 2.years.ago)
    create(:menu, user: user, name: "Applebees", created_at: 1.year.ago)
    board = severed_board("Applebees", created_at: Time.current)

    ENV["DRY_RUN"] = "false"
    expect { task.invoke }.to output(/1 board\(s\) with an ambiguous match/).to_stdout

    expect(board.reload.parent_type).to eq("User")
  end

  # The board is created in the same request as its menu, so when several menus
  # share a name the one created alongside it is the right one.
  it "picks the Menu created alongside the board when names collide" do
    create(:menu, user: user, name: "Applebees", created_at: 2.years.ago)
    same_request = create(:menu, user: user, name: "Applebees", created_at: Time.current)
    board = severed_board("Applebees", created_at: Time.current)

    ENV["DRY_RUN"] = "false"
    task.invoke

    expect(board.reload.parent_id).to eq(same_request.id)
  end

  it "never touches a board that still has its Menu parent" do
    menu = create(:menu, user: user, name: "Applebees")
    intact = create(:board, user: user, name: "Applebees", board_type: "menu",
                            parent_type: "Menu", parent_id: menu.id)

    ENV["DRY_RUN"] = "false"
    expect { task.invoke }.to output(/re-linked 0 board/).to_stdout

    expect(intact.reload.parent_id).to eq(menu.id)
  end

  it "scopes to one owner with USER_ID" do
    other = create(:user)
    create(:menu, user: user, name: "Applebees")
    create(:menu, user: other, name: "Dennys")
    mine = severed_board("Applebees")
    theirs = create(:board, user: other, name: "Dennys", board_type: "menu",
                            parent_type: "User", parent_id: other.id)

    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = user.id.to_s
    task.invoke

    expect(mine.reload.parent_type).to eq("Menu")
    expect(theirs.reload.parent_type).to eq("User")
  end
end
