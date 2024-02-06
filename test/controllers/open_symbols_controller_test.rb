require "test_helper"

class OpenSymbolsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get open_symbols_index_url
    assert_response :success
  end

  test "should get show" do
    get open_symbols_show_url
    assert_response :success
  end
end
