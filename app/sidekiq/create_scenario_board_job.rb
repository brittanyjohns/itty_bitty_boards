class CreateScenarioBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: true, backtrace: true

  def perform(prompt_id)
    begin
      puts "CreateScenarioBoardJob.perform_async(#{prompt_id})"
      Rails.logger.info "CreateScenarioBoardJob.perform_async(#{prompt_id})"
      scenario = Scenario.find(prompt_id)

      new_board_after = scenario.create_board_with_images
      puts "new_board: #{new_board_after}"
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      Rails.logger.error "**** ERROR **** \n#{e.message}\n #{e.backtrace}"
    end
  end
end
