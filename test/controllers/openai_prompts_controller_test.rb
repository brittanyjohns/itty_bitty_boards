require "test_helper"

class OpenaiPromptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @openai_prompt = openai_prompts(:one)
  end

  test "should get index" do
    get openai_prompts_url
    assert_response :success
  end

  test "should get new" do
    get new_openai_prompt_url
    assert_response :success
  end

  test "should create openai_prompt" do
    assert_difference("OpenaiPrompt.count") do
      post openai_prompts_url, params: { openai_prompt: { deleted_at: @openai_prompt.deleted_at, private: @openai_prompt.private, prompt_text: @openai_prompt.prompt_text, response_type: @openai_prompt.response_type, revised_prompt: @openai_prompt.revised_prompt, send_now: @openai_prompt.send_now, sent_at: @openai_prompt.sent_at, user_id: @openai_prompt.user_id } }
    end

    assert_redirected_to openai_prompt_url(OpenaiPrompt.last)
  end

  test "should show openai_prompt" do
    get openai_prompt_url(@openai_prompt)
    assert_response :success
  end

  test "should get edit" do
    get edit_openai_prompt_url(@openai_prompt)
    assert_response :success
  end

  test "should update openai_prompt" do
    patch openai_prompt_url(@openai_prompt), params: { openai_prompt: { deleted_at: @openai_prompt.deleted_at, private: @openai_prompt.private, prompt_text: @openai_prompt.prompt_text, response_type: @openai_prompt.response_type, revised_prompt: @openai_prompt.revised_prompt, send_now: @openai_prompt.send_now, sent_at: @openai_prompt.sent_at, user_id: @openai_prompt.user_id } }
    assert_redirected_to openai_prompt_url(@openai_prompt)
  end

  test "should destroy openai_prompt" do
    assert_difference("OpenaiPrompt.count", -1) do
      delete openai_prompt_url(@openai_prompt)
    end

    assert_redirected_to openai_prompts_url
  end
end
