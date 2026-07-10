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

          # A self-create's status is plan-driven: a Free user's MySpeak account
          # is a no-login sandbox ("MySpeak Free account"); paid plans get a real
          # owned (active) communicator. Free's one full slot is claim/hand-off
          # only (see Permissions::CommunicatorLimits). Over-cap is 422.
          status = Permissions::CommunicatorLimits.self_create_status(
            user: current_user,
            requested: ChildAccount::ACTIVE,
          )
          allowed, http_status, slot_error =
            Permissions::CommunicatorLimits.can_create?(
              user: current_user,
              status: status,
            )
          unless allowed
            render json: { error: "communicator_slot_unavailable", message: slot_error },
                   status: http_status
            return
          end

          name = params[:name].to_s.strip
          if name.blank?
            render json: { error: "Onboarding failed", details: ["Name can't be blank"] },
                   status: :unprocessable_content
            return
          end

          pronouns       = params[:pronouns].to_s.strip
          care_notes     = params[:care_notes].to_s
          board_id       = params[:board_id]
          photo_data_url = params[:photo_data_url].to_s
          contacts       = Array(params[:contacts])

          # Safety profiles get an unguessable random slug, assigned by
          # Profile#ensure_slug when the slug is left blank, so a child's public
          # emergency page (`/my/<slug>`) can't be found by guessing their name.
          # We deliberately ignore any client-supplied slug (the wizard no longer
          # collects one) — random is non-negotiable for safety pages.
          #
          # We still derive a readable, unique *username* from the name: it's the
          # account handle shown on the page a responder already scanned, not the
          # public URL, so keeping it human-readable doesn't weaken discovery
          # protection.
          base_slug = name.parameterize.presence || "communicator-#{SecureRandom.hex(3)}"
          unique = unique_slug_for(base_slug)

          profile = nil
          child = nil

          ActiveRecord::Base.transaction do
            # `communicator_accounts` uses `owner_id` as the FK; set `user`
            # explicitly so downstream `api_view`s (which read
            # `child.user.pro?` etc.) don't see a nil user.
            #
            # `status` is plan-driven (see above): a Free user's MySpeak account
            # is a no-login sandbox; paid plans get a full (active) communicator.
            # Sandbox communicators still appear on the family dashboard — the
            # index lists every owned account regardless of status.
            child = current_user.communicator_accounts.create!(
              name: name,
              username: unique,
              user: current_user,
              status: status,
            )

            # No `slug:` — left blank so Profile#ensure_slug assigns the random
            # `s-xxxxxx` safety slug (slug_type "random", not user-editable).
            profile = Profile.new(
              profileable: child,
              profile_kind: "safety",
              username: unique,
              bio: care_notes,
              settings: build_settings(pronouns: pronouns, contacts: contacts),
            )

            attach_photo(profile, photo_data_url, unique) if photo_data_url.present?

            profile.save!

            attach_starter_board(child, board_id)
            ensure_team_for(child)
          end

          # Fall back to a generated initials avatar when the parent
          # skipped the photo step. The Safety ID card and Device Tag
          # both embed the avatar, so without this they render with a
          # broken image slot.
          begin
            profile.set_fake_avatar unless profile.avatar.attached?
          rescue StandardError => e
            Rails.logger.warn "[Onboarding::Myspeak#create] set_fake_avatar failed: #{e.message}"
          end

          profile.generate_attachments! if profile.safety?
          # The owner is creating their OWN profile here, so echo the full
          # settings back (page-safe + sensitive). The public #safety_view
          # withholds the sensitive keys; this authenticated create response
          # doesn't need to — the owner just typed this data in.
          render json: profile.safety_view.merge(
            settings: profile.public_settings(kind: :safety)
                             .merge(profile.safety_sensitive_settings),
          ), status: :created
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn "[Onboarding::Myspeak#create] #{e.record.class}: #{e.record.errors.full_messages.join(", ")}"
          render json: {
            error: "Onboarding failed",
            details: e.record.errors.full_messages,
          }, status: :unprocessable_content
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

          # Deep clone: a starter board with folder tiles gets its linked
          # sub-boards cloned + rewired too (usually a no-op — starters are
          # flat today).
          begin
            cloned = Boards::AssignmentCloner.new(board, owner: current_user,
                                                         communicator: child,
                                                         voice: child.voice,
                                                         name: board.name).call
          rescue Boards::AssignmentCloner::CloneError => e
            Rails.logger.warn "[Onboarding::Myspeak] clone failed for board #{board.id}: #{e.message}"
            return
          end

          # The root clone gets a ChildBoard join row (inside
          # clone_with_images). Mark it the communicator's favorite to match
          # the old behavior (the wizard's pick is the home board).
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
        # `ChildAccount#ensure_team!` does the admin-add (issue #226).
        def ensure_team_for(child)
          team_name = child.name.present? ? "#{child.name}'s Communication Team" : "Communication Team"
          child.ensure_team!(creator: current_user, name: team_name)
        end
      end
    end
  end
end
