class AddVoiceToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :voice, :string
    add_column :boards, :voice, :string
    BoardImage.find_each do |bi|
      bi.update!(voice: "echo")
    end
    Board.find_each do |b|
      b.update!(voice: "echo")
    end
  end
end
