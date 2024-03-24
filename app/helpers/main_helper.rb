module MainHelper
    def add_team_intro
        "<p class='text-center font-bold'>Click here to add a new team.</p> <br><p class='text-center'>Teams allow you to share your boards with others.</p>".html_safe
    end

    def account_details_intro
        "<p class='text-center font-bold'>This is your user profile.</p> <br><p class='text-center'>You can edit your profile, view your boards, menus, and images.</p>".html_safe
    end

    def board_from_scratch_intro
        "<p class='text-center font-bold'>Create a new board from scratch.</p> <br><p class='text-center'>
       Just pick a name & start adding items to your board. <br> <br>You'll be able to upload your own images or use our built-in image search.</p>".html_safe
    end

    def board_from_scenario_intro
        "<p class='text-center font-bold'>Create a new board from any scenario.</p> <br><p class='text-center'>
        Enter a scenario & we'll generate a board for you. <br> <br> You'll be able to edit the board to your liking.</p>".html_safe
    end

    def invite_team_members_intro
        "<p class='text-center font-bold'>Invite new members to your team.</p> <br><p class='text-center'>
        Just enter their email address & we'll send them an invite. <br> <br> You can also edit/remove members of teams you are an admin of.</p>".html_safe
    end

    def share_team_board_intro
        "<p class='text-center font-bold'>Share a board with your team.</p> <br><p class='text-center'>
        Just select a board & we'll share it with your team. <br> <br> You can also edit/remove boards you've shared with your team.</p>".html_safe
    end
end
