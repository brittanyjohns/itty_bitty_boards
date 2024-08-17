class SaveAudioUrls < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :audio_url, :string
    add_column :images, :audio_url, :string

    Image.includes(:audio_files_attachments).find_each do |image|
      image_audio_file = image.audio_files.first
      image.update!(audio_url: image_audio_file.url) if image_audio_file.present?
    end
    BoardImage.includes(image: :audio_files_attachments).find_each do |board_image|
      audio_file = board_image.image.find_audio_for_voice(board_image.voice)
      board_image.update!(audio_url: audio_file.url) if audio_file.present?
    end
    Board.includes(:audio_files_attachments).find_each do |board|
      board_audio_file = board.audio_files.first
      board.update!(audio_url: board_audio_file.url) if board_audio_file.present?
    end
  end
end
