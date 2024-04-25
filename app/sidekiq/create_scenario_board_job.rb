class CreateScenarioBoardJob
  include Sidekiq::Job

  def perform(prompt_id)
    puts "CreateScenarioBoardJob.perform_async(#{prompt_id})"
    openai_prompt = OpenaiPrompt.find(prompt_id)
    openai_prompt.set_scenario_description
    response = openai_prompt.send_prompt_to_openai if openai_prompt.send_now
    parsed_response = response[:content] if response
    puts "parsed_response: #{parsed_response}"
    openai_prompt.create_board_from_response(parsed_response, openai_prompt.token_limit) if parsed_response
    openai_prompt.update!(sent_at: Time.now)
  end
end
