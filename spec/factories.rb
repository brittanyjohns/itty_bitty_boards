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
    name { "testing 123" }
    user
    parent_id { user.id }
    parent_type { "User" }
  end

  factory(:team) do
    name { "testing 123" }
    created_by { FactoryBot.create(:user) }
  end

  factory(:image) do
    label { "testing 123" }
    next_words { ["i", "am", "a", "test"] }
  end

  factory(:doc) do
    documentable { FactoryBot.create(:image) }
    user
  end

  factory(:board_image) do
    board { FactoryBot.create(:board) }
    image { FactoryBot.create(:image) }
    skip_create_voice_audio { true }
  end
end
