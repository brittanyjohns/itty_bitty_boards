require "application_system_test_case"

class BetaRequestsTest < ApplicationSystemTestCase
  setup do
    @beta_request = beta_requests(:one)
  end

  test "visiting the index" do
    visit beta_requests_url
    assert_selector "h1", text: "Beta requests"
  end

  test "should create beta request" do
    visit beta_requests_url
    click_on "New beta request"

    fill_in "Email", with: @beta_request.email
    click_on "Create Beta request"

    assert_text "Beta request was successfully created"
    click_on "Back"
  end

  test "should update Beta request" do
    visit beta_request_url(@beta_request)
    click_on "Edit this beta request", match: :first

    fill_in "Email", with: @beta_request.email
    click_on "Update Beta request"

    assert_text "Beta request was successfully updated"
    click_on "Back"
  end

  test "should destroy Beta request" do
    visit beta_request_url(@beta_request)
    click_on "Destroy this beta request", match: :first

    assert_text "Beta request was successfully destroyed"
  end
end
