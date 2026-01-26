class AddPartOfSpeechToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :part_of_speech, :string, default: "default", null: false
    BoardImage.reset_column_information
    BoardImage.includes(:image).find_each do |board_image|
      pos = board_image.image.part_of_speech || "default"
      board_image.update_column(:part_of_speech, pos)
    end
  end
end
