module VMS
  # ====================
  # Group menu
  # ====================

  def self.open_group_menu
    loop do
      group = VMS.group_data
      if group.nil?
        choice = VMS.message(VMS::GROUP_NOT_IN_GROUP_MESSAGE, [_INTL("Create Group"), _INTL("Settings"), _INTL("Cancel")], -1)
        if choice == 1
          VMS.group_settings_menu
          next
        end
        return if choice != 0
        VMS.group_create
        VMS.message(VMS::GROUP_CREATED_MESSAGE)
        VMS.group_invite_menu
        next
      end
      leader = VMS.group_leader?
      commands = []
      commands.push([:members, _INTL("Members")])
      commands.push([:invite, _INTL("Invite Player")]) if leader
      commands.push([:double, _INTL("Double Battle")])
      commands.push([:multi, _INTL("Group 2v2")]) if leader
      commands.push([:ready, _INTL("Ready Check")]) if leader
      commands.push([:settings, _INTL("Settings")])
      commands.push([:coop_test, _INTL("Co-op Battle (Debug)")]) if $DEBUG && VMS::ENABLE_COOP
      commands.push([:leave, leader ? _INTL("Disband Group") : _INTL("Leave Group")])
      commands.push([:cancel, _INTL("Cancel")])
      title = _INTL(VMS::GROUP_MENU_MESSAGE, group[:members].length, VMS::GROUP_MAX_SIZE)
      choice = VMS.message(title, commands.map { |c| c[1] }, -1)
      return if choice.nil? || choice < 0
      case commands[choice][0]
      when :members
        return if VMS.group_members_menu == :close
      when :invite
        VMS.group_invite_menu
      when :double
        member = VMS.group_pick_member(_INTL("Battle who?"))
        next if member.nil?
        VMS.group_battle_request(member, :double)
        return
      when :multi
        return if VMS.group_start_2v2
      when :ready
        VMS.group_run_ready_check
      when :settings
        VMS.group_settings_menu
      when :coop_test
        $game_temp.vms[:group_pending_coop_test] = true
        return
      when :leave
        next unless pbConfirmMessage(leader ? VMS::GROUP_DISBAND_CONFIRM_MESSAGE : VMS::GROUP_LEAVE_CONFIRM_MESSAGE)
        VMS.group_clear
        return
      else
        return
      end
    end
  end

  # Usage: VMS.group_pick_member(message #<String>) (returns the chosen online group member, or nil)
  def self.group_pick_member(message)
    members = VMS.group_members
    if members.empty?
      VMS.message(_INTL("There are no other members online."))
      return nil
    end
    leader_id = VMS.group_data[:leader]
    names = members.map { |m| (m.id == leader_id) ? _INTL("{1} (Leader)", m.name) : m.name }
    choice = VMS.message(message, names + [_INTL("Cancel")], -1)
    return nil if choice.nil? || choice < 0 || choice >= members.length
    return members[choice]
  end

  # Returns :close when the pause menu should close (battle started, teleport queued).
  def self.group_members_menu
    loop do
      member = VMS.group_pick_member(_INTL("Choose a member."))
      return nil if member.nil?
      commands = []
      commands.push([:party, _INTL("View Party")])
      commands.push([:double, _INTL("Double Battle")])
      commands.push([:single, _INTL("Single Battle")])
      commands.push([:teleport, _INTL("Teleport To")]) if VMS::GROUP_ALLOW_TELEPORT
      commands.push([:kick, _INTL("Remove")]) if VMS.group_leader?
      commands.push([:cancel, _INTL("Cancel")])
      choice = VMS.message(_INTL(VMS::GROUP_MEMBER_MESSAGE, member.name), commands.map { |c| c[1] }, -1)
      next if choice.nil? || choice < 0
      case commands[choice][0]
      when :party
        VMS.see_party(member.id)
      when :double, :single
        VMS.group_battle_request(member, commands[choice][0])
        return :close
      when :teleport
        $game_temp.vms[:group_pending_teleport] = member.id
        return :close
      when :kick
        VMS.group_kick(member.id) if pbConfirmMessage(_INTL(VMS::GROUP_KICK_CONFIRM_MESSAGE, member.name))
      end
    end
  end

  def self.group_invite_menu
    group = VMS.group_data
    return if group.nil? || !VMS.group_leader?
    if group[:members].length + group[:invites].length >= VMS::GROUP_MAX_SIZE
      VMS.message(VMS::GROUP_FULL_MESSAGE)
      return
    end
    candidates = VMS.get_players.select do |player|
      player.id != $player.id && !group[:members].include?(player.id) &&
        !group[:invites].key?(player.id) && VMS.group_of(player).nil?
    end
    if candidates.empty?
      VMS.message(VMS::GROUP_NO_ONE_TO_INVITE)
      return
    end
    choice = VMS.message(VMS::GROUP_INVITE_WHO_MESSAGE, candidates.map(&:name) + [_INTL("Cancel")], -1)
    return if choice.nil? || choice < 0 || choice >= candidates.length
    player = candidates[choice]
    if VMS.group_invite(player)
      VMS.message(_INTL(VMS::GROUP_INVITE_SENT_MESSAGE, player.name))
    else
      VMS.message(VMS::GROUP_FULL_MESSAGE)
    end
  end

  # Runs actions picked in the Group menu that must wait until the pause menu has closed.
  def self.group_do_pending_actions
    id = $game_temp.vms.delete(:group_pending_teleport)
    VMS.teleport_to(id) if id
    VMS.coop_wild_battle(*VMS::COOP_DEBUG_WILD_ARGS) if $game_temp.vms.delete(:group_pending_coop_test)
  end

  # ====================
  # Group battles
  # ====================

  # Asks for a party size like the Battle option does. Returns [true, size] or [false, nil].
  def self.group_pick_battle_size(player, type)
    unless $player.able_pokemon_count >= 1 && VMS.update_party(player).any? { |pkmn| pkmn&.able? }
      VMS.message(_INTL(VMS::INTERACTION_NO_BATTLE_MESSAGE, player.name))
      return [false, nil]
    end
    size_choices = (type == :single) ? [VMS::PARTY_SIZE_3, VMS::PARTY_SIZE_6, _INTL("No Limit")] : [VMS::PARTY_SIZE_4, VMS::PARTY_SIZE_6, _INTL("No Limit")]
    size_choice = VMS.message(VMS::SELECT_PARTY_SIZE_MESSAGE, size_choices + [_INTL("Cancel")], -1)
    return [false, nil] if size_choice.nil? || size_choice < 0 || size_choice == size_choices.length
    size = nil
    size = (type == :single) ? [3, 6][size_choice] : [4, 6][size_choice] if size_choice < 2
    needed = size || 1
    if $player.able_pokemon_count < needed || VMS.update_party(player).count { |pkmn| pkmn&.able? } < needed
      VMS.message(VMS::NOT_ENOUGH_POKEMON_MESSAGE)
      return [false, nil]
    end
    return [true, size]
  end

  # Sends a battle request straight to another player, skipping the Swap/Trade/Battle/Gift
  # menu. Uses the same handshake as VMS.send_interaction, so the other player sees the
  # normal "wants to interact" prompt followed by the battle confirmation.
  def self.group_battle_request(player, type)
    id = player.id
    player_name = player.name
    if player.busy
      VMS.message(_INTL(VMS::INTERACTION_BUSY_MESSAGE, player_name))
      return
    end
    ok, size = VMS.group_pick_battle_size(player, type)
    return unless ok
    begin
      $game_temp.vms[:state] = [:interact_send, id]
      msgwindow = pbCreateMessageWindow
      msgwindow.letterbyletter = true
      msgwindow.text = _INTL(VMS::INTERACTION_WAIT_RESPONSE_MESSAGE, player_name)
      VMS.get_interaction_time.times do
        VMS.scene_update
        msgwindow.update
        player = VMS.get_player(id)
        break if player.nil?
        break if VMS::INTERACTION_WAIT <= 0 && Input.trigger?(Input::BACK)
        break if player.state[1] == $player.id
      end
      pbDisposeMessageWindow(msgwindow)
      if player.nil?
        VMS.message(_INTL(VMS::PLAYER_DISCONNECT_MESSAGE, player_name))
        return
      end
      if player.state[1] != $player.id
        VMS.message(_INTL(VMS::PLAYER_NO_RESPONSE_MESSAGE, player_name))
        return
      end
      battle_seed = rand(1000000...9999999)
      $game_temp.vms[:state] = [:battle, id, type, size, battle_seed]
      if !VMS.await_player_state(player, :battle, _INTL(VMS::INTERACTION_WAIT_RESPONSE_MESSAGE, player_name))
        VMS.message(_INTL(VMS::INTERACTION_CANCEL_MESSAGE, player_name))
        return
      end
      VMS.start_battle(player, type, size, battle_seed)
    ensure
      $game_temp.vms[:state] = [:idle, nil]
    end
  end

  def self.group_enter_lobby(lobby_id, team_idx, slot_idx)
    $game_temp.vms[:mb_lobby_id] = lobby_id
    $game_temp.vms[:mb_team_idx] = team_idx
    $game_temp.vms[:mb_slot_idx] = slot_idx
    $game_temp.vms[:state] = [:multibattle_lobby, lobby_id, team_idx, slot_idx]
    VMS.log("Group: Entering lobby #{lobby_id} on team #{team_idx}, slot #{slot_idx}")
    VMS.mb_lobby_wait_loop(lobby_id)
  end

  # Leader picks a partner, the other two become the opposing team, and every member
  # is asked to join the same 2v2 lobby with their slot already assigned.
  # Returns true if a lobby was started.
  def self.group_start_2v2
    group = VMS.group_data
    others = VMS.group_members
    if group[:members].length != 4 || others.length != 3
      VMS.message(VMS::GROUP_2V2_NEED_FOUR_MESSAGE)
      return false
    end
    choice = VMS.message(VMS::GROUP_2V2_PARTNER_MESSAGE, others.map(&:name) + [_INTL("Cancel")], -1)
    return false if choice.nil? || choice < 0 || choice >= others.length
    partner = others[choice]
    foes = others - [partner]
    lobby_id = rand(10000...99999)
    group[:battle] = [lobby_id, {
      $player.id  => [0, 0],
      partner.id  => [0, 1],
      foes[0].id  => [1, 0],
      foes[1].id  => [1, 1]
    }]
    begin
      VMS.group_enter_lobby(lobby_id, 0, 0)
    ensure
      group = VMS.group_data
      group[:battle] = nil if group
    end
    return true
  end
end

MenuHandlers.add(:pause_menu, :vms_group, {
  "name"      => proc {
    group = VMS.group_data
    next group ? _INTL("{1} ({2}/{3})", VMS::GROUP_MENU_NAME, group[:members].length, VMS::GROUP_MAX_SIZE) : VMS::GROUP_MENU_NAME
  },
  "order"     => 48,
  "condition" => proc {
    VMS::ENABLE_GROUPS &&
    VMS::ACCESSIBLE_PROC.call &&
    VMS::ACCESSIBLE_FROM_PAUSE_MENU &&
    VMS.is_connected? &&
    $game_temp.vms[:state][0] == :idle
  },
  "effect"    => proc { |menu|
    menu.pbHideMenu
    VMS.open_group_menu
    menu.pbEndScene
    VMS.group_do_pending_actions
    next true
  }
})
