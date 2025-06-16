FactoryBot.define do
  factory :vendor do
    user_id { 1 }
    business_name { "MyString" }
    business_email { "MyString" }
    website { "MyString" }
    location { "MyString" }
    category { "MyString" }
    verified { false }
  end

  factory :organization do
    name { "MyString" }
    slug { "MyString" }
    admin_user_id { 1 }
  end

  factory :contest_entry do
    name { "MyString" }
    email { "MyString" }
    data { "MyString" }
  end

  factory :event do
    name { "MyString" }
    slug { "MyString" }
    date { "MyString" }
  end

  factory :profile do
    profileable { nil }
    username { "MyString" }
    slug { "MyString" }
  end

  factory :team_account do
    team { nil }
    account { nil }
    active { false }
    settings { "MyString" }
  end

  factory :scenario do
    questions { "" }
    answers { "" }
    name { "MyString" }
    initial_description { "MyText" }
    age_range { "MyString" }
  end

  factory :prompt_template do
    prompt_type { "MyString" }
    response_type { "MyString" }
    prompt_text { "MyText" }
    preprompt_text { "MyText" }
    quantity { 1 }
  end

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
    email { FFaker::Internet.email }
    password { FFaker::Internet.password }
    role { "user" }
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
    board
    image
  end

  factory(:menu) do
    name { "My Menu" }
    description { "A sample menu for testing." }
    user
    predefined { false }
  end

  factory(:menu_doc) do
    menu
    doc { FactoryBot.create(:doc) }
    user
  end
end
