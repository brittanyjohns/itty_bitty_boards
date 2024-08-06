FactoryBot.define do
  factory :board_group_board do
    board_group { nil }
    board { nil }
  end

  factory :board_group do
    name { "MyString" }
    layout { "MyString" }
    predefined { false }
  end

  factory :child_board do
    board { nil }
    child_account { nil }
    status { "MyString" }
  end

  factory :child_account do
    
  end

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
