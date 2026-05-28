module API
  module V1
    module Onboarding
      class MyspeakController < API::ApplicationController
        STARTER_BOARD_SLUGS = {
          "basics"   => "myspeak-basics",
          "feelings" => "myspeak-feelings",
          "social"   => "myspeak-social",
        }.freeze

        MAX_SLUG_TRIES = 50

        def create
          unless current_user.can_create_myspeak_id?
            limit = current_user.myspeak_id_limit
            render json: {
              error: "myspeak_id_limit_reached",
              message: "Free accounts are limited to #{limit} MySpeak ID. Upgrade to Basic or Pro to add more.",
              limit: limit,
              count: current_user.myspeak_id_count,
            }, status: :forbidden
            return
          end

          name = params[:name].to_s.strip
          if name.blank?
            render json: { error: "Onboarding failed", details: ["Name can't be blank"] },
                   status: :unprocessable_entity
            return
          end

          pronouns       = params[:pronouns].to_s.strip
          care_notes     = params[:care_notes].to_s
          board_id       = params[:board_id].to_s
          photo_data_url = params[:photo_data_url].to_s
          contacts       = Array(params[:contacts])

          base_slug = name.parameterize.presence || "communicator-#{SecureRandom.hex(3)}"
          unique = unique_slug_for(base_slug)

          profile = nil

          ActiveRecord::Base.transaction do
            # `communicator_accounts` uses `owner_id` as the FK; set `user`
            # explicitly so downstream `api_view`s (which read
            # `child.user.pro?` etc.) don't see a nil user.
            child = current_user.communicator_accounts.create!(
              name: name,
              username: unique,
              user: current_user,
            )

            profile = Profile.new(
              profileable: child,
              profile_kind: "safety",
              username: unique,
              slug: unique,
              bio: care_notes,
              settings: build_settings(pronouns: pronouns, contacts: contacts),
            )

            attach_photo(profile, photo_data_url, unique) if photo_data_url.present?

            profile.save!

            attach_starter_board(child, board_id)
          end

          profile.generate_attachments! if profile.safety?
          render json: profile.safety_view, status: :created
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn "[Onboarding::Myspeak#create] #{e.record.class}: #{e.record.errors.full_messages.join(", ")}"
          render json: {
            error: "Onboarding failed",
            details: e.record.errors.full_messages,
          }, status: :unprocessable_entity
        end

        private

        def build_settings(pronouns:, contacts:)
          settings = {}
          settings["pronouns"] = pronouns if pronouns.present?

          slot = 1
          contacts.each do |c|
            attrs = c.respond_to?(:to_unsafe_h) ? c.to_unsafe_h : c.to_h
            name  = attrs["name"].to_s.strip
            phone = attrs["phone"].to_s.strip
            rel   = attrs["relationship"].to_s.strip
            next if name.blank? && phone.blank?

            settings["ice_contact_#{slot}"] = {
              "name" => name,
              "relationship" => rel,
              "phone" => phone,
            }
            slot += 1
            break if slot > 5
          end

          settings
        end

        def attach_photo(profile, data_url, slug)
          match = data_url.match(/\Adata:(?<ct>[\w\/+\-.]+);base64,(?<b64>.+)\z/m)
          return unless match

          content_type = match[:ct]
          bytes = Base64.decode64(match[:b64])
          return if bytes.blank?

          ext = content_type.split("/").last.split("+").first
          ext = "png" if ext.blank?

          profile.avatar.attach(
            io: StringIO.new(bytes),
            filename: "#{slug}.#{ext}",
            content_type: content_type,
          )
        end

        def attach_starter_board(child, board_id)
          slug = STARTER_BOARD_SLUGS[board_id]
          return unless slug

          board = Board.find_by(slug: slug)
          unless board
            Rails.logger.warn "[Onboarding::Myspeak] starter board #{slug.inspect} missing — skipping attachment"
            return
          end

          ChildBoard.create!(
            board: board,
            child_account: child,
            created_by: current_user,
            favorite: true,
          )
        end

        def unique_slug_for(base)
          candidate = base
          (1..MAX_SLUG_TRIES).each do |i|
            candidate = (i == 1 ? base : "#{base}-#{i}")
            return candidate unless slug_or_username_taken?(candidate)
          end
          "#{base}-#{SecureRandom.hex(3)}"
        end

        def slug_or_username_taken?(value)
          Profile.exists?(slug: value) ||
            Profile.exists?(username: value) ||
            ChildAccount.exists?(username: value)
        end
      end
    end
  end
end
