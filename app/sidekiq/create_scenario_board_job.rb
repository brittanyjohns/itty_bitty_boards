class CreateScenarioBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: true, backtrace: true

  def perform(prompt_id)
    begin
      puts "CreateScenarioBoardJob.perform_async(#{prompt_id})"
      Rails.logger.info "CreateScenarioBoardJob.perform_async(#{prompt_id})"
      openai_prompt = OpenaiPrompt.find(prompt_id)
      openai_prompt.set_scenario_description
      response = openai_prompt.send_prompt_to_openai if openai_prompt.send_now
      parsed_response = response[:content] if response
      puts "JOB parsed_response: #{parsed_response}"
      Rails.logger.info "JOB parsed_response: #{parsed_response["word_phrases"]&.count}"
      response_text = response[:content].gsub("```json", "").gsub("```", "").strip if response
      puts "**JOB response_text: #{response_text}"
      new_board_after = openai_prompt.create_board_from_response(response_text, openai_prompt.token_limit) if response_text
      puts "new_board: #{new_board_after}"
      openai_prompt.update!(sent_at: Time.now)
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      Rails.logger.error "**** ERROR **** \n#{e.message}\n #{e.backtrace}"
    end
  end
end
