#===============================================================================
# Shared story progress.
#
# After the host wins a co-op trainer battle, the rest of that event usually
# hands out the reward: a badge, a TM, self switch A (trainer beaten), story
# switches. The host's game takes a snapshot right after the battle, waits for
# the event to finish, and sends the partner whatever changed. The partner's
# game applies the same changes, so they don't have to beat the battle again.
#===============================================================================
class PokemonGlobalMetadata
  attr_writer :vms_applied_progress

  def vms_applied_progress
    @vms_applied_progress ||= []
    return @vms_applied_progress
  end
end

module VMS
  # ====================
  # Host: recording
  # ====================

  def self.coop_progress_snapshot
    items = {}
    $bag.pockets.each do |pocket|
      next if !pocket
      pocket.each { |item, qty| items[item] = (items[item] || 0) + qty }
    end
    return {
      switches:      $game_switches.instance_variable_get(:@data).dup,
      variables:     Marshal.load(Marshal.dump($game_variables.instance_variable_get(:@data))),
      self_switches: $game_self_switches.instance_variable_get(:@data).dup,
      badges:        $player.badges.dup,
      items:         items
    }
  end

  def self.coop_progress_start(partner_id)
    return unless VMS::COOP_SHARE_PROGRESS
    $game_temp.vms[:coop_progress] = {
      partner_id: partner_id,
      before:     VMS.coop_progress_snapshot,
      started:    Time.now
    }
  end

  # Returns the changes between two snapshots, limited to what the config shares.
  def self.coop_progress_diff(before, after)
    changes = {}
    if VMS::COOP_SHARE_BADGES
      badges = []
      after[:badges].each_with_index { |owned, i| badges.push(i) if owned && !before[:badges][i] }
      changes[:badges] = badges if !badges.empty?
    end
    if VMS::COOP_SHARE_SWITCHES
      switches = {}
      [before[:switches].length, after[:switches].length].max.times do |id|
        next if VMS::COOP_SHARE_EXCLUDED_SWITCHES.include?(id)
        switches[id] = !!after[:switches][id] if !!before[:switches][id] != !!after[:switches][id]
      end
      changes[:switches] = switches if !switches.empty?
    end
    if VMS::COOP_SHARE_VARIABLES
      variables = {}
      [before[:variables].length, after[:variables].length].max.times do |id|
        next if VMS::COOP_SHARE_EXCLUDED_VARIABLES.include?(id)
        variables[id] = after[:variables][id] if before[:variables][id] != after[:variables][id]
      end
      changes[:variables] = variables if !variables.empty?
    end
    if VMS::COOP_SHARE_SELF_SWITCHES
      self_switches = {}
      (before[:self_switches].keys | after[:self_switches].keys).each do |key|
        value = (after[:self_switches][key] == true)
        self_switches[key] = value if (before[:self_switches][key] == true) != value
      end
      changes[:self_switches] = self_switches if !self_switches.empty?
    end
    if VMS::COOP_SHARE_ITEMS
      items = {}
      after[:items].each do |item, qty|
        gained = qty - (before[:items][item] || 0)
        items[item] = gained if gained > 0
      end
      changes[:items] = items if !items.empty?
    end
    return changes
  end

  # Runs every frame: once the battle's event is over, sends the changes to the partner.
  def self.coop_progress_update
    recording = $game_temp&.vms&.[](:coop_progress)
    return if recording.nil?
    timed_out = Time.now - recording[:started] > VMS::COOP_SHARE_EVENT_TIMEOUT
    return if pbMapInterpreterRunning? && !timed_out
    $game_temp.vms[:coop_progress] = nil
    group = VMS.group_data
    return if group.nil?
    changes = VMS.coop_progress_diff(recording[:before], VMS.coop_progress_snapshot)
    return if changes.empty?
    group[:progress] = [rand(1000000...9999999), recording[:partner_id], changes]
    group[:progress_sent_at] = Time.now
    VMS.log("Co-op: Sharing progress with #{recording[:partner_id]}: #{changes.keys.join(', ')}")
  end

  # Stops sending once the partner confirms, or after a while if they never do.
  def self.coop_progress_check_ack(group)
    progress = group[:progress]
    return if progress.nil?
    ack = VMS.group_of(VMS.get_player(progress[1]))&.[](:progress_ack)
    if ack == progress[0] || Time.now - group[:progress_sent_at] > 300
      group[:progress] = nil
      group[:progress_sent_at] = nil
    end
  end

  # ====================
  # Partner: applying
  # ====================

  def self.group_check_shared_progress
    group = VMS.group_data
    return if group.nil?
    VMS.coop_progress_check_ack(group)
    VMS.get_players.each do |player|
      next if player.id == $player.id
      progress = VMS.group_of(player)&.[](:progress)
      next unless progress.is_a?(Array) && progress[1] == $player.id
      next unless group[:members].include?(player.id)
      applied = $PokemonGlobal.vms_applied_progress
      if applied.include?(progress[0])
        group[:progress_ack] = progress[0]
        next
      end
      if VMS.group_setting(:receive_progress)
        summary = VMS.coop_progress_apply(progress[2])
        VMS.message(_INTL(VMS::COOP_PROGRESS_RECEIVED_MESSAGE, player.name, summary)) if !summary.empty?
      end
      applied.push(progress[0])
      applied.shift while applied.length > 50
      group[:progress_ack] = progress[0]
      return
    end
  end

  # Applies shared changes and returns a short description of them.
  def self.coop_progress_apply(changes)
    parts = []
    badges = (changes[:badges] || []).reject { |i| $player.badges[i] }
    badges.each { |i| $player.badges[i] = true }
    parts.push(badges.length == 1 ? _INTL("a Badge") : _INTL("{1} Badges", badges.length)) if !badges.empty?
    items = []
    (changes[:items] || {}).each do |item, qty|
      next if !GameData::Item.exists?(item) || !$bag.can_add?(item, qty)
      $bag.add(item, qty)
      item_data = GameData::Item.get(item)
      items.push((qty > 1) ? _INTL("{1} x{2}", item_data.name, qty) : item_data.name)
    end
    parts.push(items.join(", ")) if !items.empty?
    flags = 0
    (changes[:switches] || {}).each do |id, value|
      next if $game_switches[id] == value
      $game_switches[id] = value
      flags += 1
    end
    (changes[:variables] || {}).each do |id, value|
      current = $game_variables[id]
      if VMS::COOP_SHARE_VARIABLES_KEEP_HIGHER && value.is_a?(Numeric) && current.is_a?(Numeric)
        value = [current, value].max
      end
      next if current == value
      $game_variables[id] = value
      flags += 1
    end
    (changes[:self_switches] || {}).each do |key, value|
      next if $game_self_switches[key] == value
      $game_self_switches[key] = value
      flags += 1
    end
    parts.push(_INTL("story progress")) if flags > 0
    $game_map.need_refresh = true if $game_map && flags > 0
    return parts.join(", ")
  end
end

EventHandlers.add(:on_frame_update, :vms_coop_progress,
  proc { VMS.coop_progress_update }
)
