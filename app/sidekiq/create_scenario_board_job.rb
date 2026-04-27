class CreateScenarioBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: true, backtrace: true

  def perform(prompt_id)
    begin
      scenario = Scenario.find(prompt_id)

      new_board_after = scenario.create_board_with_images
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n #{e.backtrace}"
    end
  end
end
