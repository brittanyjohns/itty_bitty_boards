class AddVoiceToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :voice, :string
    add_column :board, :voice, :string
    BoardImage.find_each do |bi|
      bi.update!(voice: "alloy")
    end
    Board.find_each do |b|
      b.update!(voice: "alloy")
    end
  end
end
