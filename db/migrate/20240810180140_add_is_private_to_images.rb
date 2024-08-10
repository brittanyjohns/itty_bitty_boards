class AddIsPrivateToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :is_private, :boolean, default: false
    Image.update_all(private: false, is_private: false, user_id: User::DEFAULT_ADMIN_ID)
  end
end
