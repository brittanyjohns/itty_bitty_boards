module API
  module V1
    module Onboarding
      class MyspeakController < API::ApplicationController
        MAX_SLUG_TRIES = 50

        def create
          # Validated first: a blank name fails on every path, and answering it
          # with a slot or picker error would send the user hunting for the
          # wrong problem.
          name = params[:name].to_s.strip
          if name.blank?
            render json: { error: "Onboarding failed", details: ["Name can't be blank"] },
                   status: :unprocessable_content
            return
          end

          # A communicator's MySpeak page is free on every plan. The only quota
          # here is the COMMUNICATOR SLOT below (Permissions::CommunicatorLimits)
          # — every communicator auto-mints exactly one Profile, so counting
          # Profiles charged the same limit twice and refused a page our copy
          # promises is free (#761).
          #
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

          # Out of slots is not the end of the road. A Free user gets exactly
          # ONE self-create, and adding a communicator from the dashboard
          # spends it — while silently minting that communicator's MySpeak page
          # (ChildAccount#create_profile!) and leaving it blank. So the user
          # refused here is usually the user whose page already exists, unset:
          # #761's fix stopped that page being double-counted, but the wizard
          # still had only one move — create a NEW communicator — so she stayed
          # stuck, one slot short of a page she already owned.
          #
          # Set up THAT page instead. Adoption runs only when a create is
          # refused, so the ordinary path is untouched.
          target = allowed ? nil : adoption_target

          if !allowed && target.nil?
            candidates = adoptable_communicators
            if candidates.size > 1
              # Several blank pages and no `communicator_id` to disambiguate.
              # Guessing would write a child's emergency details onto the wrong
              # page, so ask instead — the ids come back for the picker.
              render json: {
                error: "communicator_selection_required",
                message: "Choose which communicator this page is for.",
                communicators: candidates.map { |c| { id: c.id, name: c.name, username: c.username } },
              }, status: :unprocessable_content
              return
            end

            # A hard stop at the END of a multi-step wizard. Captured
            # server-side because the user who hits it is often the one who
            # never accepted the cookie banner, so the frontend sees nothing
            # (#766).
            Analytics::CommunicatorEvents.slot_limit_reached(
              user: current_user,
              status: status,
              source: Analytics::CommunicatorEvents::MYSPEAK_ONBOARDING,
            )
            render json: { error: "communicator_slot_unavailable", message: slot_error },
                   status: http_status
            return
          end

          pronouns       = params[:pronouns].to_s.strip
          # About Me is the PUBLIC bio shown on the open MySpeak page.
          # Emergency notes are PRIVATE — they live behind the gated
          # safety_view reveal (Profile::SAFETY_SENSITIVE_KEYS) and print on
          # the Safety ID card. The wizard now collects the two separately.
          about_me       = params[:about_me].to_s
          emergency_notes = params[:emergency_notes].to_s
          # Legacy fallback: an old frontend sends only `care_notes`. It was
          # framed as safety info, so route it to the PRIVATE emergency notes
          # (never the public bio) — privacy wins during the deploy gap.
          care_notes     = params[:care_notes].to_s
          resolved_emergency_notes =
            emergency_notes.presence || (about_me.blank? ? care_notes.presence : nil)
          board_id       = params[:board_id]
          photo_data_url = params[:photo_data_url].to_s
          contacts       = Array(params[:contacts])

          profile = nil
          child = nil
          adopted = target.present?

          ActiveRecord::Base.transaction do
            child, profile =
              if adopted
                adopt_communicator(target, name: name)
              else
                build_communicator(name: name, status: status)
              end

            # Merge rather than replace the settings hash: `never_set_up?`
            # guarantees the keys the wizard writes are empty, but says nothing
            # about theme settings someone may have picked, and those are not
            # this wizard's to discard.
            #
            # bio = About Me (public). Left blank when a legacy client sends
            # only care_notes, so nothing leaks safety text onto the public page.
            profile.assign_attributes(
              profile_kind: "safety",
              bio: about_me,
              settings: (profile.settings || {}).merge(
                build_settings(
                  pronouns: pronouns,
                  contacts: contacts,
                  emergency_notes: resolved_emergency_notes,
                ),
              ),
            )

            attach_photo(profile, photo_data_url, profile.username) if photo_data_url.present?

            profile.save!

            attach_starter_board(child, board_id)
            ensure_team_for(child)
          end

          # Reported here — the commit above is the moment the communicator and
          # its page exist. Anything below is rendering, and a Grover failure
          # must not be able to lose the record that they were created.
          #
          # This route builds its communicator entirely server-side, so it never
          # touches the frontend form the legacy `communicator account created`
          # event lives in — every communicator made through the wizard was
          # uncounted before #766.
          if adopted
            # No account was created — do not let this land in a create count.
            Analytics::CommunicatorEvents.myspeak_page_adopted(
              user: current_user,
              profile: profile,
              child: child,
              source: Analytics::CommunicatorEvents::MYSPEAK_ONBOARDING,
            )
          else
            Analytics::CommunicatorEvents.account_created(
              user: current_user,
              child: child,
              source: Analytics::CommunicatorEvents::MYSPEAK_ONBOARDING,
            )
            Analytics::CommunicatorEvents.myspeak_page_created(
              user: current_user,
              profile: profile,
              child: child,
              source: Analytics::CommunicatorEvents::MYSPEAK_ONBOARDING,
            )
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
          # `adopted` tells the frontend this page was set up on a communicator
          # the user already had, rather than a new one — the difference the
          # confirmation copy needs. Status stays :created either way: from the
          # caller's side the MySpeak page did not exist before this request.
          render json: profile.safety_view.merge(
            adopted: adopted,
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

        # Communicators this user owns whose MySpeak page has never been set up
        # — either no Profile at all, or the blank auto-minted one. These are
        # the only pages the wizard may write to when there is no slot left.
        def adoptable_communicators
          @adoptable_communicators ||=
            current_user.communicator_accounts
                        .includes(:profile)
                        .order(:created_at)
                        .select { |c| c.profile.nil? || c.profile.never_set_up? }
        end

        # Which communicator to adopt. An explicit `communicator_id` wins (the
        # picker's answer). Otherwise adopt only when there is exactly one
        # candidate — choosing among several would write one child's emergency
        # details onto another child's page.
        def adoption_target
          requested = params[:communicator_id].presence
          if requested
            match = adoptable_communicators.find { |c| c.id.to_s == requested.to_s }
            unless match
              Rails.logger.warn "[Onboarding::Myspeak] communicator_id #{requested.inspect} is not adoptable for user #{current_user.id}"
            end
            return match
          end

          adoptable_communicators.size == 1 ? adoptable_communicators.first : nil
        end

        # Set this wizard's page up on a communicator that already exists.
        #
        # The rename is deliberate: `Profile#safety_view` reads its `name` from
        # `profileable.name`, so without it the name the parent just typed would
        # be dropped from the page it names. `username` is left alone — that is
        # the account handle, and on an active communicator it backs a private
        # sign-in.
        def adopt_communicator(child, name:)
          child.update!(name: name) if child.name != name

          profile = child.profile ||
                    Profile.new(
                      profileable: child,
                      username: unique_slug_for(
                        child.sluggify_for_profile(child.username).presence ||
                          name.parameterize.presence ||
                          "communicator-#{SecureRandom.hex(3)}",
                      ),
                    )

          # An auto-minted page carries a NAME-DERIVED slug: create_profile!
          # passes `slug:` explicitly, so Profile#ensure_slug never runs and the
          # random-slug rule never applies. That is precisely the guessable
          # `/my/<name>` URL a safety page must not have, and adoption is about
          # to put emergency contacts behind it. Re-slug now — `never_set_up?`
          # is what guarantees nobody has shared the old link yet.
          if profile.persisted? && profile.slug_type != "random"
            profile.slug = Profile.generate_random_slug
            profile.slug_type = "random"
          end

          [child, profile]
        end

        # The ordinary path: a brand-new communicator and its page.
        #
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
        def build_communicator(name:, status:)
          base_slug = name.parameterize.presence || "communicator-#{SecureRandom.hex(3)}"
          unique = unique_slug_for(base_slug)

          # `communicator_accounts` uses `owner_id` as the FK; set `user`
          # explicitly so downstream `api_view`s (which read `child.user.pro?`
          # etc.) don't see a nil user.
          #
          # `status` is plan-driven: a Free user's MySpeak account is a no-login
          # sandbox; paid plans get a full (active) communicator. Sandbox
          # communicators still appear on the family dashboard — the index lists
          # every owned account regardless of status.
          child = current_user.communicator_accounts.create!(
            name: name,
            username: unique,
            user: current_user,
            status: status,
          )

          # No `slug:` — left blank so Profile#ensure_slug assigns the random
          # `s-xxxxxx` safety slug (slug_type "random", not user-editable).
          [child, Profile.new(profileable: child, username: unique)]
        end

        def build_settings(pronouns:, contacts:, emergency_notes: nil)
          settings = {}
          settings["pronouns"] = pronouns if pronouns.present?
          # Sensitive: withheld from page-open, revealed only by the gated
          # safety_view POST (Profile::SAFETY_SENSITIVE_KEYS).
          settings["emergency_notes"] = emergency_notes if emergency_notes.present?

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
