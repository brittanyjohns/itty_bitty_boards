# lib/tasks/demo_public_profiles.rake
# Usage:
#   bundle exec rake demo:public_profiles                       # creates 5 demo users (pro) + 1 public profile each
#   bundle exec rake demo:public_profiles COUNT=20              # creates 20 demo users (pro) + 1 public profile each
#   bundle exec rake demo:public_profiles USER_ID=123 COUNT=3   # creates 3 public profiles on that single user
#   bundle exec rake demo:public_profiles USER_ID=123 PER_USER=1 COUNT=3
#     -> creates 3 demo users? (ignored), but if USER_ID is given and PER_USER=1, it will create 1 profile for that user (COUNT ignored)
#
# Notes:
# - This task does NOT attach ActiveStorage avatars (because that requires a file or remote fetch).
#   If you want, I can add Dicebear avatar attach like your model already supports.

namespace :demo do
  desc "Create demo public profile pages (profile_kind: public_page)"
  task public_profiles: :environment do
    require "securerandom"
    require "ffaker"

    count   = (ENV["COUNT"] || "1").to_i
    user_id = ENV["USER_ID"]&.to_i
    per_user = ENV["PER_USER"].to_s == "1"

    puts "== demo:public_profiles =="
    puts "COUNT=#{count} USER_ID=#{user_id || "nil"} PER_USER=#{per_user}"

    def normalize_url(raw)
      v = (raw || "").strip
      return "" if v.empty?
      return v if v.start_with?("http://", "https://")
      return v if v.start_with?("@") # you sometimes allow handles
      if v.include?(".") && !v.include?(" ")
        "https://#{v}"
      else
        v
      end
    end

    def safe_slug(base)
      base.to_s.downcase
          .gsub(/[^a-z0-9]+/, "-")
          .gsub(/\A-+|-+\z/, "")
          .presence || SecureRandom.hex(4)
    end

    def unique_username_slug!(username)
      slug = safe_slug(username)
      # Avoid collisions on Profile.username or Profile.slug
      if Profile.exists?(username: username) || Profile.exists?(slug: slug)
        suffix = SecureRandom.hex(2)
        username = "#{username}#{suffix}"
        slug = safe_slug(username)
      end
      [username, slug]
    end

    def fake_public_page_settings
      display_name = FFaker::Name.name
      headline_pool = [
        "AAC resources - classroom-friendly - quick tips",
        "Speech support - core words - real-life boards",
        "SLP tools - teacher-friendly boards - easy setup",
        "AAC made simple - modeled language - practical boards",
        "Parent + educator resources - print + device-ready"
      ]

      about_pool = [
        "I create practical AAC boards for everyday routines, classrooms, and home life. Use this page to grab resources, follow along, or share with a team.",
        "Here you'll find communication boards, tips, and resources I use with families and classrooms. Bookmark this page and share it when you need it.",
        "I make ready-to-use AAC boards and visual supports for real life-snack time, play, transitions, and learning. Grab links below and explore featured boards."
      ]

      accent_colors = ["#4F46E5", "#0EA5E9", "#10B981", "#F97316", "#EC4899", "#8B5CF6", "#111827"]

      # A few “links” (your custom links section)
      links = []
      link_titles = [
        "Free AAC starter pack",
        "Classroom routine boards",
        "My printable bundle",
        "My favorite modeling tips",
        "Resource library"
      ].shuffle

      link_titles.first(2).each do |title|
        url = [
          "example.com/resources/#{SecureRandom.hex(3)}",
          "example.com/downloads/#{SecureRandom.hex(3)}",
          "example.com/links/#{SecureRandom.hex(3)}"
        ].sample
        links << {
          "title" => title,
          "url" => normalize_url(url),
          "kind" => "other"
        }
      end

      # Socials + shop_links (your quick links section)
      ig_handle = FFaker::Internet.user_name
      tiktok_handle = FFaker::Internet.user_name
      site = "#{FFaker::Internet.domain_name}/#{FFaker::Internet.user_name}"

      {
        "display_name" => display_name,
        "headline" => headline_pool.sample,
        "about" => about_pool.sample,
        "links" => links,
        "socials" => {
          "website" => normalize_url(site),
          "instagram" => normalize_url("instagram.com/#{ig_handle}"),
          "tiktok" => normalize_url("tiktok.com/@#{tiktok_handle}"),
          "youtube" => normalize_url("youtube.com/@#{FFaker::Internet.user_name}"),
          "facebook" => normalize_url("facebook.com/#{FFaker::Internet.user_name}"),
          "linkedin" => normalize_url("linkedin.com/in/#{FFaker::Internet.user_name}")
        },
        "shop_links" => {
          "etsy" => normalize_url("etsy.com/shop/#{FFaker::Lorem.word.capitalize}#{FFaker::Lorem.word.capitalize}"),
          "tpt" => normalize_url("teacherspayteachers.com/Store/#{FFaker::Lorem.word.capitalize}-#{FFaker::Lorem.word.capitalize}")
        },
        "theme" => {
          "accent" => accent_colors.sample,
          "layout" => ["cards", "simple", "minimal"].sample
        }
      }
    end

    def ensure_demo_user!
      # We don't know your exact User schema, so we keep it minimal:
      # - email required is typical
      # - plan_type / plan_status you've shown in your controller
      base_name = FFaker::Internet.user_name
      username, slug = unique_username_slug!(base_name)
      email = "#{username}@speakanyway.dev"

      user = User.find_by(email: email)
      return user if user

      user = User.new(email: email)

      # Try to set fields you mentioned; guard with respond_to? so it won't crash if your column names differ
      user.plan_type = "pro" if user.respond_to?(:plan_type=)
      user.plan_status = "active" if user.respond_to?(:plan_status=)
      user.username = email.split("@").first if user.respond_to?(:username=)

      # If you have Devise, you may require password
      if user.respond_to?(:password=) && user.password.blank?
        user.password = "111111"
        user.password_confirmation = user.password if user.respond_to?(:password_confirmation=)
      end

      # Some apps require settings hash
      if user.respond_to?(:settings) && user.settings.nil?
        user.settings = {}
      end

      user.save!
      user
    end

    def create_public_profile_for_user!(user)
      base_name = FFaker::Internet.user_name
      username, slug = unique_username_slug!(base_name)

      public_page = fake_public_page_settings

      intro = "Hi, I'm #{public_page["display_name"]}. Welcome! Here are my favorite AAC resources and featured boards."
      bio = [
        "I share practical AAC boards and classroom-friendly resources. Use the links below to explore and save what you need.",
        "AAC doesn't have to be perfect - it just has to be available. Grab resources and explore featured boards below.",
        "I build boards for real life: routines, play, transitions, and learning. Save this page and share it with your team."
      ].sample

      sku = loop do
        candidate = "DEMO-PUB-#{SecureRandom.hex(6).upcase}"
        break candidate unless Profile.exists?(sku: candidate)
      end

      settings = {
        "profile_kind" => "public_page",
        "public_page" => public_page
      }

      profile = Profile.create!(
        profileable: user,
        profile_kind: "public_page",
        username: username,
        slug: slug,
        intro: intro,
        bio: bio,
        settings: settings,
        placeholder: false,
        claimed_at: Time.zone.now,
        claim_token: nil,
        sku: sku
      )
      profile.set_fake_avatar

      puts "Created Profile ##{profile.id} slug=#{profile.slug} user_id=#{user.id}"
      profile
    end

    created = []

    if user_id.present?
      user = User.find_by(id: user_id)
      raise "User not found for USER_ID=#{user_id}" unless user

      if per_user
        created << create_public_profile_for_user!(user)
      else
        count.times { created << create_public_profile_for_user!(user) }
      end
    else
      # Default behavior: make COUNT users, each gets 1 profile
      count.times do
        user = ensure_demo_user!
        created << create_public_profile_for_user!(user)
        puts "User: #{user.id} \n email: #{user.email} \n password: #{user.password} \n slug: #{user.slug}\npublic_url: #{user.public_url}"
      end
    end

    puts "== Done. Created #{created.length} public profiles."
    exit
  end
end
