require "test_helper"

class TeamBoardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @team_board = team_boards(:one)
  end

  test "should get index" do
    get team_boards_url
    assert_response :success
  end

  test "should get new" do
    get new_team_board_url
    assert_response :success
  end

  test "should create team_board" do
    assert_difference("TeamBoard.count") do
      post team_boards_url, params: { team_board: { allow_edit: @team_board.allow_edit, board_id: @team_board.board_id, team_id: @team_board.team_id } }
    end

    assert_redirected_to team_board_url(TeamBoard.last)
  end

  test "should show team_board" do
    get team_board_url(@team_board)
    assert_response :success
  end

  test "should get edit" do
    get edit_team_board_url(@team_board)
    assert_response :success
  end

  test "should update team_board" do
    patch team_board_url(@team_board), params: { team_board: { allow_edit: @team_board.allow_edit, board_id: @team_board.board_id, team_id: @team_board.team_id } }
    assert_redirected_to team_board_url(@team_board)
  end

  test "should destroy team_board" do
    assert_difference("TeamBoard.count", -1) do
      delete team_board_url(@team_board)
    end

    assert_redirected_to team_boards_url
  end
end
