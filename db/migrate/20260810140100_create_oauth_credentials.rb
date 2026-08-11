class CreateOauthCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_credentials do |t|
      t.string :provider, null: false
      t.text :refresh_token
      t.text :access_token
      t.datetime :access_token_expires_at
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :oauth_credentials, :provider, unique: true
  end
end
