class AddRevisedPromptToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :revised_prompt, :string
    add_column :images, :image_type, :string
  end
end
