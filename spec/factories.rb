FactoryBot.define do
  factory :vendor do
    association :user
    business_name { FFaker::Company.name }
    business_email { FFaker::Internet.email }
    website { FFaker::Internet.http_url }
    location { FFaker::Address.city }
    category { "aac" }
    verified { false }
  end

  factory :organization do
    name { FFaker::Company.name }
    slug { FFaker::Internet.slug }
    admin_user_id { FactoryBot.create(:user).id }
  end

  factory :contest_entry do
    name { FFaker::Name.name }
    email { FFaker::Internet.email }
    data { "{}" }
  end

  factory :event do
    name { FFaker::Name.name }
    slug { FFaker::Internet.slug }
    date { 1.week.from_now.to_s }
  end

  factory :profile do
    profileable { nil }
    sequence(:username) { |n| "user_#{n}" }
    sequence(:slug) { |n| "user-#{n}" }
  end

  factory :team_account do
    team { nil }
    account { nil }
    active { false }
    settings { "{}" }
  end

  factory :scenario do
    questions { "" }
    answers { "" }
    name { FFaker::Lorem.words(3).join(" ") }
    initial_description { FFaker::Lorem.paragraph }
    age_range { "5-10" }
  end

  factory :prompt_template do
    prompt_type { "board" }
    response_type { "json" }
    prompt_text { FFaker::Lorem.paragraph }
    preprompt_text { FFaker::Lorem.paragraph }
    quantity { 1 }
  end

  factory :board_group_board do
    board_group { nil }
    board { nil }
  end

  factory :board_group do
    name { FFaker::Lorem.words(2).join(" ") }
    layout { "{}" }
    predefined { false }
  end

  factory :child_board do
    board { nil }
    child_account { nil }
    status { "active" }
  end

  factory :child_account do
    association :user
    sequence(:username) { |n| "child_#{n}" }
  end

  factory(:user) do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    role { "user" }
  end

  factory(:admin_user, class: "User") do
    sequence(:email) { |n| "admin#{n}@example.com" }
    password { "password123" }
    role { "admin" }
  end

  factory(:board) do
    sequence(:name) { |n| "Board #{n}" }
    sequence(:slug) { |n| "board-#{n}" }
    user
    parent_id { user.id }
    parent_type { "User" }
  end

  factory(:team) do
    name { FFaker::Company.name }
    created_by { FactoryBot.create(:user) }
  end

  factory(:image) do
    sequence(:label) { |n| "image_#{n}" }
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
    name { FFaker::Lorem.words(2).join(" ") }
    description { FFaker::Lorem.sentence }
    user
    predefined { false }
  end

  factory(:menu_doc) do
    menu
    doc { FactoryBot.create(:doc) }
    user
  end
end
