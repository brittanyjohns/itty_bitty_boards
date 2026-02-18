class UpdateBoardsVoiceJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  def perform(board_ids, voice_value, language = "en")
    boards = Board.where(id: board_ids)
    boards.update_all(voice: voice_value)
    boards.each do |board|
      board.set_voice
    end
  end
end
