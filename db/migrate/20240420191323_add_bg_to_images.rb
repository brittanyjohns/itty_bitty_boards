class AddBgToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :bg_color, :string
    add_column :images, :text_color, :string
    add_column :images, :font_size, :integer
    add_column :images, :border_color, :string
  end
end
