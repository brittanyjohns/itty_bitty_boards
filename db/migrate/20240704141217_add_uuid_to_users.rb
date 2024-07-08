class AddUuidToUsers < ActiveRecord::Migration[7.1]
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
    add_column :users, :uuid, :uuid, default: "gen_random_uuid()"
    add_index :users, :uuid, unique: true
    User.find_each do |user|
      # uuid = "gen_random_uuid()"
      uuid = SecureRandom.uuid
      puts "Updating user #{user.id} with UUID: #{uuid}"
      user.update(uuid: uuid)
    end
  end

  def down
    remove_column :users, :uuid
  end
end
