module VMS
  # ===========
  # Groups
  # ===========
  # Whether or not the Group option is shown in the pause menu while connected.
  ENABLE_GROUPS = true
  # The name of the Group option in the pause menu.
  GROUP_MENU_NAME = "Group"
  # Maximum number of players in a group, including the leader. (4 allows a group 2v2)
  GROUP_MAX_SIZE = 4
  # Seconds before an unanswered group invite expires.
  GROUP_INVITE_TIMEOUT = 30
  # Seconds a player waits for the leader to confirm them after accepting an invite.
  GROUP_JOIN_TIMEOUT = 10
  # Whether or not group members can teleport to each other from the Group menu.
  GROUP_ALLOW_TELEPORT = true
  # Packet key used to sync group data. Must not collide with VMS::PACKET_KEYS.
  GROUP_PACKET_KEY = 100
  # Default for the "Party HUD" setting (shows group members in the corner of the map).
  GROUP_HUD_DEFAULT = true
  # Seconds the leader waits for everyone to answer a ready check.
  GROUP_READY_CHECK_TIMEOUT = 30

  # ===========
  # Co-op Battles
  # ===========
  # Whether VMS.coop_trainer_battle / VMS.coop_wild_battle invite a group member.
  # When false (or nobody is available) they behave like normal solo battles.
  ENABLE_COOP = true
  # How many Pokémon each player brings into a co-op battle.
  COOP_PARTY_SIZE = 3
  # Seconds to wait for the partner to answer the invite.
  COOP_INVITE_TIMEOUT = 30
  # Seconds to wait for the partner to pick their Pokémon.
  COOP_SELECTION_TIMEOUT = 90
  # If the partner declines or doesn't answer, fight the battle alone instead.
  COOP_FALLBACK_SOLO = true
  # Whether the player who joined someone else's battle blacks out if it's lost.
  # (The host follows the event's own battle rules, e.g. setBattleRule("canLose").)
  COOP_GUEST_BLACKS_OUT = false
  # Whether both players get prize money for beating a trainer.
  COOP_PRIZE_MONEY = true
  # Seconds to keep battle data available after a battle ends, so the partner can finish.
  COOP_LINGER_SECONDS = 10
  # Whether random wild encounters invite a nearby group member into a co-op battle.
  # If they decline or don't answer in time, the encounter is fought solo.
  COOP_AUTO_WILD = true
  # How close (in tiles, on the same map) a member must be for an encounter to invite them.
  # Set to 0 to invite anyone on the same map.
  COOP_AUTO_DISTANCE = 8
  # Seconds to wait for the partner to answer an encounter invite (shorter than event invites).
  COOP_AUTO_INVITE_TIMEOUT = 15
  # Default for the "Co-op Story Battles" setting. When on, every trainer battle
  # (gyms, rivals, route trainers...) offers to bring a group member along.
  COOP_STORY_DEFAULT = true
  # How close (in tiles, on the same map) a member must be to join a story battle.
  # Set to 0 to allow anyone on the same map.
  COOP_STORY_DISTANCE = 0
  # Whether players can use items from their Bag (Potions, etc.) in co-op battles.
  COOP_ALLOW_ITEMS = true
  # Whether Poké Balls can be thrown in co-op wild battles. The player who threw
  # the ball keeps the Pokémon. (Balls come from the Bag, so this also needs
  # COOP_ALLOW_ITEMS.)
  COOP_ALLOW_CATCHING = true
  # Whether Pokémon gain Exp (and EVs) from co-op battles. Each player's own
  # Pokémon get it after the battle, so learning a move can't put the two games
  # out of step mid-battle.
  COOP_EXP = true
  # Shared story progress: after a won co-op trainer battle, whatever the battle's
  # event changes next (badges, switches, self switches, variables, items) is
  # copied to the partner too, so both players can carry on with the story.
  COOP_SHARE_PROGRESS = true
  COOP_SHARE_BADGES        = true
  COOP_SHARE_SWITCHES      = true
  COOP_SHARE_SELF_SWITCHES = true
  COOP_SHARE_VARIABLES     = true
  COOP_SHARE_ITEMS         = true
  # Switches/variables never shared (e.g. temporary ones your events reuse).
  # Variable 1 holds the last battle's result, so it's excluded by default.
  COOP_SHARE_EXCLUDED_SWITCHES  = []
  COOP_SHARE_EXCLUDED_VARIABLES = [1]
  # For number variables, the partner keeps whichever value is higher, so
  # story-progress counters never go backwards for someone who is further ahead.
  COOP_SHARE_VARIABLES_KEEP_HIGHER = true
  # Seconds to wait for the battle's event to finish before sending the changes anyway.
  COOP_SHARE_EVENT_TIMEOUT = 120
  # Wild battle used by the "Co-op Battle (Debug)" option in the Group menu (Debug mode only).
  COOP_DEBUG_WILD_ARGS = [:PIDGEY, 5, :RATTATA, 5]

  # ===========
  # Group Messages
  # ===========
  GROUP_NOT_IN_GROUP_MESSAGE    = _INTL("You're not in a group.")
  GROUP_MENU_MESSAGE            = _INTL("Group ({1}/{2})")
  GROUP_CREATED_MESSAGE         = _INTL("You created a group!")
  GROUP_INVITE_WHO_MESSAGE      = _INTL("Invite who?")
  GROUP_NO_ONE_TO_INVITE        = _INTL("There's no one available to invite.")
  GROUP_INVITE_SENT_MESSAGE     = _INTL("Invited {1} to the group.")
  GROUP_FULL_MESSAGE            = _INTL("The group is full.")
  GROUP_INVITE_RECEIVED_MESSAGE = _INTL("{1} invited you to their group. Join?")
  GROUP_JOINED_MESSAGE          = _INTL("{1} joined the group!")
  GROUP_LEFT_MESSAGE            = _INTL("{1} left the group.")
  GROUP_JOIN_FAILED_MESSAGE     = _INTL("Couldn't join the group. It may be full or the invite expired.")
  GROUP_KICKED_MESSAGE          = _INTL("You were removed from the group.")
  GROUP_DISBANDED_MESSAGE       = _INTL("The group was disbanded.")
  GROUP_LEAVE_CONFIRM_MESSAGE   = _INTL("Leave the group?")
  GROUP_DISBAND_CONFIRM_MESSAGE = _INTL("Disband the group?")
  GROUP_KICK_CONFIRM_MESSAGE    = _INTL("Remove {1} from the group?")
  GROUP_MEMBER_MESSAGE          = _INTL("What do you want to do with {1}?")
  GROUP_2V2_NEED_FOUR_MESSAGE   = _INTL("A group 2v2 needs exactly 4 members.")
  GROUP_2V2_PARTNER_MESSAGE     = _INTL("Who will be your partner?")
  GROUP_2V2_CALL_MESSAGE        = _INTL("{1} started a group 2v2 battle! Your team: {2}. Join?")

  GROUP_READY_ASK_MESSAGE       = _INTL("{1} is asking: are you ready?")
  GROUP_READY_ALL_MESSAGE       = _INTL("Everyone is ready!")
  GROUP_READY_NOT_MESSAGE       = _INTL("Not ready: {1}")
  GROUP_CHAT_PREFIX             = "[G] "
  COOP_PROGRESS_RECEIVED_MESSAGE = _INTL("{1} shared progress from your battle together: {2}.")

  COOP_PICK_PARTNER_MESSAGE     = _INTL("Who will battle with you?")
  COOP_CONFIRM_PARTNER_MESSAGE  = _INTL("Battle together with {1}?")
  COOP_BATTLE_ALONE             = _INTL("Battle alone")
  COOP_INVITE_MESSAGE           = _INTL("{1} wants you to join their battle against {2}! Join?")
  COOP_WAIT_RESPONSE_MESSAGE    = _INTL("Waiting for {1} to respond...")
  COOP_WAIT_SELECTION_MESSAGE   = _INTL("Waiting for {1} to choose Pokémon...")
  COOP_DECLINED_MESSAGE         = _INTL("{1} can't join the battle.")
  COOP_CANCELLED_MESSAGE        = _INTL("The co-op battle was cancelled.")
  COOP_WAIT_BATTLE_MESSAGE      = _INTL("Waiting for {1}...")
  COOP_PARTNER_LOST_MESSAGE     = _INTL("Lost contact with {1}! Their Pokémon will fight on their own.")
  COOP_PARTNER_FLED_MESSAGE     = _INTL("{1} ran from the battle!")
  COOP_RUN_CONFIRM_MESSAGE      = _INTL("Run away? The battle will end for your partner too.")
end
