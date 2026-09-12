module Boards
  # Which boards may this user READ because a team put a communicator in their
  # care? (Issue #923.)
  #
  # The read-side sibling of `Boards::TeamCuration`, and the same walk with one
  # difference: no role gate. `Board#viewable_by?` granted a non-owner access by
  # exactly two routes — a `team_boards` shelf row, or `team_curatable_by?`,
  # which is `User::CURATE_ROLES`-only by design — so a `member` ("Support") or
  # `restricted` ("Read-Only") invitee on a team whose communicator had an
  # attached board could see the child and none of the child's boards. A parent
  # invites a grandparent as Support *so that* she can help with the board; the
  # two roles that mean "use it, don't change it" were the two that could not
  # use anything.
  #
  # `ChildAccount#viewable_by?` has said the rule all along — every team role is
  # a legitimate reader, and a Support member watching how the week went does
  # not get to change the boards. This makes the board side agree.
  #
  # REACHABILITY, not attachment, for the same reason curating is: assignment
  # attaches the ROOT of a set and its folder pages carry no `child_boards` row,
  # so an attachment-only answer opens a Core 84 root and 404s its Food page.
  # It is also what makes this fix reach every EXISTING team with no data
  # migration — `ChildBoard#register_on_communicator_team` writes a
  # `team_boards` row for boards attached from now on, but a board attached
  # before that hook existed has none and never will.
  #
  # Nothing here widens WRITING. `Board#can_edit_for` still ends in
  # `team_curatable_by?`, `TEAM_CURATION_ACTIONS` is untouched, and the
  # no-delete rule stands.
  class TeamReading < TeamCuration
    def initialize(user, limit: nil)
      super(user, limit: limit, roles: TeamUser::ROLES)
    end
  end
end
