require "test_helper"

class Api::BoardsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get api_boards_index_url
    assert_response :success
  end

  test "should get show" do
    get api_boards_show_url
    assert_response :success
  end
end
