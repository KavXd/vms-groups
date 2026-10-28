#===============================================================================
# Group data is sent as one extra field in each player's VMS packet.
# Both the Integrated and External servers forward unknown keys untouched,
# so no server changes are needed.
#
# Leader broadcasts:  { gid:, leader:, members: [ids], invites: [ids], battle: }
# Member broadcasts:  { gid:, leader: }
# Not in a group:     {}
#
# The leader is the source of truth for who is in the group. A member only
# counts as joined once they appear in the leader's member list.
#===============================================================================
VMS::PACKET_KEYS[:vms_group] = VMS::GROUP_PACKET_KEY
VMS::REVERSE_KEYS[VMS::GROUP_PACKET_KEY] = :vms_group

module VMS
  class Player
    attr_accessor :vms_group
  end

  class << self
    alias vms_group_generate_player_data generate_player_data unless method_defined?(:vms_group_generate_player_data)
    alias vms_group_update update unless method_defined?(:vms_group_update)
    alias vms_group_leave leave unless method_defined?(:vms_group_leave)

    def generate_player_data
      data = vms_group_generate_player_data
      data[VMS::GROUP_PACKET_KEY] = VMS.group_packet
      return data
    end

    def update
      vms_group_update
      VMS.group_maintain if VMS::ENABLE_GROUPS && VMS.is_connected?
    end

    def leave(show_message = true)
      VMS.group_clear
      vms_group_leave(show_message)
    end
  end

  # ====================
  # Group state
  # ====================

  # Usage: VMS.group_data (returns the local group hash, or nil if not in a group)
  def self.group_data
    return nil if $game_temp.nil? || $game_temp.vms.nil?
    return $game_temp.vms[:group]
  end

  # Usage: VMS.group_of(player #<VMS::Player>) (returns the group data that player is broadcasting, or nil)
  def self.group_of(player)
    return nil if player.nil?
    data = player.vms_group
    return (data.is_a?(Hash) && data[:gid]) ? data : nil
  end

  def self.in_group?
    return !VMS.group_data.nil?
  end

  def self.group_leader?
    group = VMS.group_data
    return !group.nil? && group[:leader] == $player.id
  end

  # Usage: VMS.group_members (returns the online VMS::Player objects in your group, excluding you)
  def self.group_members
    group = VMS.group_data
    return [] if group.nil?
    return group[:members].filter_map { |id| (id == $player.id) ? nil : VMS.get_player(id) }
  end

  def self.group_member_name(id)
    player = VMS.get_player(id)
    return player.name if player
    group = VMS.group_data
    return (group && group[:names][id]) || "???"
  end

  def self.group_packet
    group = VMS.group_data
    return {} if group.nil?
    # Shared story progress can come from any member, not just the leader
    packet = {
      gid:          group[:gid],
      leader:       group[:leader],
      progress:     group[:progress],
      progress_ack: group[:progress_ack]
    }
    if VMS.group_leader?
      packet[:members]     = group[:members].dup
      packet[:invites]     = group[:invites].keys
      packet[:battle]      = group[:battle]
      packet[:ready_check] = group[:ready_check]
    else
      packet[:ready_answer] = group[:ready_answer]
    end
    return packet
  end

  def self.group_notice(message)
    ($game_temp.vms[:group_notices] ||= []).push(message)
  end

  # ====================
  # Group actions
  # ====================

  def self.group_create
    $game_temp.vms[:group] = {
      gid:       $player.id,
      leader:    $player.id,
      members:   [$player.id],
      invites:   {},
      names:     { $player.id => $player.name },
      battle:    nil,
      confirmed: true,
      joined_at: Time.now
    }
  end

  def self.group_join(leader)
    $game_temp.vms[:group] = {
      gid:       leader.id,
      leader:    leader.id,
      members:   [leader.id, $player.id],
      invites:   {},
      names:     { leader.id => leader.name, $player.id => $player.name },
      battle:    nil,
      confirmed: false,
      joined_at: Time.now
    }
  end

  # Leaving as the leader disbands the group, since members follow the leader's broadcast.
  def self.group_clear
    return if $game_temp.nil? || $game_temp.vms.nil?
    $game_temp.vms[:group] = nil
  end

  def self.group_invite(player)
    group = VMS.group_data
    return false if group.nil? || !VMS.group_leader?
    return false if group[:members].length + group[:invites].length >= VMS::GROUP_MAX_SIZE
    group[:invites][player.id] = Time.now
    group[:names][player.id] = player.name
    return true
  end

  def self.group_kick(id)
    group = VMS.group_data
    return if group.nil? || !VMS.group_leader? || id == $player.id
    group[:members].delete(id)
    group[:invites].delete(id)
  end

  # ====================
  # Per-tick upkeep (runs inside VMS.update, never shows messages directly)
  # ====================

  def self.group_maintain
    group = VMS.group_data
    return if group.nil?
    if VMS.group_leader?
      VMS.group_maintain_leader(group)
    else
      VMS.group_maintain_member(group)
    end
  end

  def self.group_maintain_leader(group)
    now = Time.now
    group[:invites].reject! { |id, sent_at| now - sent_at > VMS::GROUP_INVITE_TIMEOUT || VMS.get_player(id).nil? }
    # Drop members who disconnected or stopped claiming this group
    group[:members].reject! do |id|
      next false if id == $player.id
      member_group = VMS.group_of(VMS.get_player(id))
      gone = member_group.nil? || member_group[:gid] != group[:gid]
      VMS.group_notice(_INTL(VMS::GROUP_LEFT_MESSAGE, VMS.group_member_name(id))) if gone
      next gone
    end
    # Confirm invited players who accepted
    VMS.get_players.each do |player|
      next if player.id == $player.id || group[:members].include?(player.id)
      next unless group[:invites].key?(player.id)
      player_group = VMS.group_of(player)
      next unless player_group && player_group[:gid] == group[:gid]
      next if group[:members].length >= VMS::GROUP_MAX_SIZE
      group[:invites].delete(player.id)
      group[:members].push(player.id)
      group[:names][player.id] = player.name
      VMS.group_notice(_INTL(VMS::GROUP_JOINED_MESSAGE, player.name))
    end
  end

  def self.group_maintain_member(group)
    leader_group = VMS.group_of(VMS.get_player(group[:gid]))
    same_group = leader_group && leader_group[:gid] == group[:gid] && leader_group[:members].is_a?(Array)
    if same_group && leader_group[:members].include?($player.id)
      group[:confirmed] = true
      group[:members]   = leader_group[:members].dup
      group[:battle]    = leader_group[:battle]
      group[:members].each do |id|
        player = VMS.get_player(id)
        group[:names][id] = player.name if player
      end
    elsif group[:confirmed]
      VMS.group_notice(same_group ? VMS::GROUP_KICKED_MESSAGE : VMS::GROUP_DISBANDED_MESSAGE)
      VMS.group_clear
    elsif Time.now - group[:joined_at] > VMS::GROUP_JOIN_TIMEOUT
      VMS.group_notice(VMS::GROUP_JOIN_FAILED_MESSAGE)
      VMS.group_clear
    end
  end

  # ====================
  # Prompts (only on the map, when the player is free)
  # ====================

  def self.group_frame_update
    return unless VMS::ENABLE_GROUPS && VMS.is_connected?
    return unless $scene.is_a?(Scene_Map)
    return if $game_temp.vms[:group_prompting]
    state = $game_temp.vms[:state]
    return unless state.is_a?(Array) && state[0] == :idle
    return unless VMS.interaction_possible?
    $game_temp.vms[:group_prompting] = true
    begin
      notices = $game_temp.vms[:group_notices]
      if notices && !notices.empty?
        VMS.message(notices.shift)
      elsif !VMS.in_group?
        VMS.group_check_invites
      else
        if !VMS.group_leader?
          VMS.group_check_battle_call
          VMS.group_check_ready_prompt
        end
        VMS.group_check_shared_progress
      end
    ensure
      $game_temp.vms[:group_prompting] = false
    end
  end

  def self.group_check_invites
    declined = ($game_temp.vms[:group_declined] ||= {})
    VMS.get_players.each do |player|
      next if player.id == $player.id
      leader_group = VMS.group_of(player)
      invited = leader_group && leader_group[:leader] == player.id &&
                leader_group[:invites].is_a?(Array) && leader_group[:invites].include?($player.id)
      if !invited
        declined.delete(player.id)
        next
      end
      next if declined[player.id]
      if pbConfirmMessage(_INTL(VMS::GROUP_INVITE_RECEIVED_MESSAGE, player.name))
        VMS.group_join(player)
      else
        declined[player.id] = true
      end
      return
    end
  end

  def self.group_check_battle_call
    group = VMS.group_data
    return unless group[:confirmed] && group[:battle].is_a?(Array)
    lobby_id, assignments = group[:battle]
    return if $game_temp.vms[:group_battle_handled] == lobby_id
    $game_temp.vms[:group_battle_handled] = lobby_id
    slot = assignments[$player.id]
    return if slot.nil?
    team_names = assignments.select { |_id, s| s[0] == slot[0] }.keys.map { |id| VMS.group_member_name(id) }
    leader_name = VMS.group_member_name(group[:leader])
    return unless pbConfirmMessage(_INTL(VMS::GROUP_2V2_CALL_MESSAGE, leader_name, team_names.join(" & ")))
    VMS.group_enter_lobby(lobby_id, slot[0], slot[1])
  end
end

EventHandlers.add(:on_frame_update, :vms_groups,
  proc { VMS.group_frame_update }
)
