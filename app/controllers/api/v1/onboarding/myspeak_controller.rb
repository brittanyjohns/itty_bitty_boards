module API
  module V1
    module Onboarding
      class MyspeakController < API::ApplicationController
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

          # Slot check — the wizard creates a real owned (active) communicator,
          # not a Pro-only sandbox scratch space. Free has 1 slot by default
          # (FREE_PAID_COMMUNICATOR_LIMIT); over-cap is 422.
          allowed, http_status, slot_error =
            Permissions::CommunicatorLimits.can_create?(
              user: current_user,
              status: ChildAccount::ACTIVE,
            )
          unless allowed
            render json: { error: "communicator_slot_unavailable", message: slot_error },
                   status: http_status
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
          board_id       = params[:board_id]
          photo_data_url = params[:photo_data_url].to_s
          contacts       = Array(params[:contacts])

          base_slug = name.parameterize.presence || "communicator-#{SecureRandom.hex(3)}"
          unique = unique_slug_for(base_slug)

          profile = nil
          child = nil

          ActiveRecord::Base.transaction do
            # `communicator_accounts` uses `owner_id` as the FK; set `user`
            # explicitly so downstream `api_view`s (which read
            # `child.user.pro?` etc.) don't see a nil user.
            #
            # Status MUST be ACTIVE — sandbox is the no-login Pro scratch
            # space and is filtered out of the family dashboard. The
            # MySpeak wizard is the family's first real communicator.
            child = current_user.communicator_accounts.create!(
              name: name,
              username: unique,
              user: current_user,
              status: ChildAccount::ACTIVE,
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
            ensure_team_for(child)
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

        # The frontend sends a Board#id (integer) for the picked public
        # starter, "later" / nil to skip, or the string form of either. We
        # clone the picked board for current_user so admin edits to the
        # master never leak into a family's communicator, then favorite the
        # ChildBoard that clone_with_images creates.
        #
        # Anything unparseable, unknown, or not in Board.public_boards is
        # logged and skipped — the board step must never block setup.
        def attach_starter_board(child, board_id)
          return if board_id.blank?
          return if board_id.to_s == "later"

          board = Board.find_by(id: board_id.to_i)
          unless board
            Rails.logger.warn "[Onboarding::Myspeak] board id #{board_id.inspect} not found — skipping"
            return
          end

          # Allowlist against the picker's own scope. clone_with_images
          # doesn't enforce ownership, so without this guard a client could
          # send any id and clone a stranger's private board.
          unless Board.public_boards.exists?(id: board.id)
            Rails.logger.warn "[Onboarding::Myspeak] board #{board.id} is not a public board — skipping"
            return
          end

          cloned = board.clone_with_images(current_user.id, board.name, child.voice, child)
          unless cloned&.persisted?
            Rails.logger.warn "[Onboarding::Myspeak] clone failed for board #{board.id}"
            return
          end

          # clone_with_images creates the ChildBoard join row. Mark it the
          # communicator's favorite to match the old behavior (the wizard's
          # pick is the home board).
          child_board = ChildBoard.find_by(child_account: child, board: cloned)
          child_board&.update(favorite: true)
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

        # Mirrors API::ChildAccountsController#create — every new
        # communicator gets a Team with the creator as admin, so team
        # permission checks have something to anchor on later.
        def ensure_team_for(child)
          return if child.teams.exists?

          team_name = child.name.present? ? "#{child.name}'s Communication Team" : "Communication Team"
          team = Team.create!(name: team_name, created_by: current_user)
          TeamAccount.create!(team: team, account: child)
          team.add_member!(current_user, current_user.professional? ? "professional" : "admin")
        end
      end
    end
  end
end
