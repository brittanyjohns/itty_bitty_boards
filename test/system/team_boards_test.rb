require "application_system_test_case"

class TeamBoardsTest < ApplicationSystemTestCase
  setup do
    @team_board = team_boards(:one)
  end

  test "visiting the index" do
    visit team_boards_url
    assert_selector "h1", text: "Team boards"
  end

  test "should create team board" do
    visit team_boards_url
    click_on "New team board"

    check "Allow edit" if @team_board.allow_edit
    fill_in "Board", with: @team_board.board_id
    fill_in "Team", with: @team_board.team_id
    click_on "Create Team board"

    assert_text "Team board was successfully created"
    click_on "Back"
  end

  test "should update Team board" do
    visit team_board_url(@team_board)
    click_on "Edit this team board", match: :first

    check "Allow edit" if @team_board.allow_edit
    fill_in "Board", with: @team_board.board_id
    fill_in "Team", with: @team_board.team_id
    click_on "Update Team board"

    assert_text "Team board was successfully updated"
    click_on "Back"
  end

  test "should destroy Team board" do
    visit team_board_url(@team_board)
    click_on "Destroy this team board", match: :first

    assert_text "Team board was successfully destroyed"
  end
end
