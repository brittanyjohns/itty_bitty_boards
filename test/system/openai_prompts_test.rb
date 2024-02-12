require "application_system_test_case"

class OpenaiPromptsTest < ApplicationSystemTestCase
  setup do
    @openai_prompt = openai_prompts(:one)
  end

  test "visiting the index" do
    visit openai_prompts_url
    assert_selector "h1", text: "Openai prompts"
  end

  test "should create openai prompt" do
    visit openai_prompts_url
    click_on "New openai prompt"

    fill_in "Deleted at", with: @openai_prompt.deleted_at
    check "Private" if @openai_prompt.private
    fill_in "Prompt text", with: @openai_prompt.prompt_text
    fill_in "Response type", with: @openai_prompt.response_type
    fill_in "Revised prompt", with: @openai_prompt.revised_prompt
    check "Send now" if @openai_prompt.send_now
    fill_in "Sent at", with: @openai_prompt.sent_at
    fill_in "User", with: @openai_prompt.user_id
    click_on "Create Openai prompt"

    assert_text "Openai prompt was successfully created"
    click_on "Back"
  end

  test "should update Openai prompt" do
    visit openai_prompt_url(@openai_prompt)
    click_on "Edit this openai prompt", match: :first

    fill_in "Deleted at", with: @openai_prompt.deleted_at
    check "Private" if @openai_prompt.private
    fill_in "Prompt text", with: @openai_prompt.prompt_text
    fill_in "Response type", with: @openai_prompt.response_type
    fill_in "Revised prompt", with: @openai_prompt.revised_prompt
    check "Send now" if @openai_prompt.send_now
    fill_in "Sent at", with: @openai_prompt.sent_at
    fill_in "User", with: @openai_prompt.user_id
    click_on "Update Openai prompt"

    assert_text "Openai prompt was successfully updated"
    click_on "Back"
  end

  test "should destroy Openai prompt" do
    visit openai_prompt_url(@openai_prompt)
    click_on "Destroy this openai prompt", match: :first

    assert_text "Openai prompt was successfully destroyed"
  end
end
