require "test_helper"

class BetaRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @beta_request = beta_requests(:one)
  end

  test "should get index" do
    get beta_requests_url
    assert_response :success
  end

  test "should get new" do
    get new_beta_request_url
    assert_response :success
  end

  test "should create beta_request" do
    assert_difference("BetaRequest.count") do
      post beta_requests_url, params: { beta_request: { email: @beta_request.email } }
    end

    assert_redirected_to beta_request_url(BetaRequest.last)
  end

  test "should show beta_request" do
    get beta_request_url(@beta_request)
    assert_response :success
  end

  test "should get edit" do
    get edit_beta_request_url(@beta_request)
    assert_response :success
  end

  test "should update beta_request" do
    patch beta_request_url(@beta_request), params: { beta_request: { email: @beta_request.email } }
    assert_redirected_to beta_request_url(@beta_request)
  end

  test "should destroy beta_request" do
    assert_difference("BetaRequest.count", -1) do
      delete beta_request_url(@beta_request)
    end

    assert_redirected_to beta_requests_url
  end
end
