FactoryBot.define do
  factory(:user) do
    email { Faker::Internet.email }
    password { Faker::Internet.password }
  end

  factory(:board) do
    name { Faker::Lorem.word }
    user
    parent_id { user.id }
    parent_type { "User" }
  end

  factory(:team) do
    name { Faker::Lorem.word }
    created_by { FactoryBot.create(:user) }
  end

  factory(:image) do
    label { Faker::Lorem.word }
  end

  factory(:doc) do
    documentable { FactoryBot.create(:image) }
    user
  end
end
