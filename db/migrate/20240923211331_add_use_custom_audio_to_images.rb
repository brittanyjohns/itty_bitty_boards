class AddUseCustomAudioToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :use_custom_audio, :boolean, default: false
    add_index :images, :use_custom_audio
    add_column :images, :voice, :string
    add_index :images, :voice
  end
end
