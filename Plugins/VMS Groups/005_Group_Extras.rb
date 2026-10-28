#===============================================================================
# Saved settings, party HUD, group chat and ready checks.
#===============================================================================
class PokemonGlobalMetadata
  attr_writer :vms_group_settings

  def vms_group_settings
    @vms_group_settings ||= {}
    return @vms_group_settings
  end
end

module VMS
  # ====================
  # Settings (saved with the game)
  # ====================

  def self.group_setting_defaults
    return {
      hud:        VMS::GROUP_HUD_DEFAULT,
      group_chat: false,
      coop_wild:  VMS::COOP_AUTO_WILD,
      coop_story: VMS::COOP_STORY_DEFAULT,
      receive_progress: true
    }
  end

  # Usage: VMS.group_setting(:hud) (returns the player's setting, or its default)
  def self.group_setting(key)
    value = $PokemonGlobal ? $PokemonGlobal.vms_group_settings[key] : nil
    return value.nil? ? VMS.group_setting_defaults[key] : value
  end

  def self.set_group_setting(key, value)
    $PokemonGlobal.vms_group_settings[key] = value if $PokemonGlobal
  end

  def self.group_settings_menu
    loop do
      on_off = proc { |key| VMS.group_setting(key) ? _INTL("ON") : _INTL("OFF") }
      commands = []
      commands.push([:hud, _INTL("Party HUD: {1}", on_off.call(:hud))])
      if VMS::ENABLE_CHAT
        chat_mode = VMS.group_setting(:group_chat) ? _INTL("Group") : _INTL("Everyone")
        commands.push([:group_chat, _INTL("Chat: {1}", chat_mode)])
      end
      if VMS::ENABLE_COOP
        commands.push([:coop_story, _INTL("Co-op Story Battles: {1}", on_off.call(:coop_story))])
        commands.push([:coop_wild, _INTL("Co-op Wild Battles: {1}", on_off.call(:coop_wild))])
        if VMS::COOP_SHARE_PROGRESS
          commands.push([:receive_progress, _INTL("Receive Shared Progress: {1}", on_off.call(:receive_progress))])
        end
      end
      commands.push([:back, _INTL("Back")])
      choice = VMS.message(_INTL("Group settings"), commands.map { |c| c[1] }, -1)
      return if choice.nil? || choice < 0 || commands[choice][0] == :back
      key = commands[choice][0]
      VMS.set_group_setting(key, !VMS.group_setting(key))
    end
  end

  # ====================
  # Party HUD
  # ====================
  GROUP_HUD_WIDTH       = 200
  GROUP_HUD_ENTRY_HEIGHT = 38
  GROUP_HUD_PAD         = 6

  class << self
    attr_accessor :group_hud_sprite
    alias vms_group_update_chat_overlay update_chat_overlay unless method_defined?(:vms_group_update_chat_overlay)

    # VMS calls this every frame from Graphics.update, so the HUD rides along with it.
    def update_chat_overlay
      vms_group_update_chat_overlay
      VMS.update_group_hud
    end
  end

  def self.update_group_hud
    show = VMS::ENABLE_GROUPS && VMS.is_connected? && VMS.in_group? && VMS.group_setting(:hud) &&
           $scene.is_a?(Scene_Map) && !$game_temp.in_battle
    if !show
      VMS.dispose_group_hud
      return
    end
    sprite_ok = @group_hud_sprite && !@group_hud_sprite.disposed?
    return if sprite_ok && Graphics.frame_count % 10 != 0
    entries = VMS.group_hud_entries
    return if sprite_ok && entries == @group_hud_entries
    @group_hud_entries = entries
    VMS.rebuild_group_hud(entries)
  end

  def self.group_ready_check_id
    group = VMS.group_data
    return nil if group.nil?
    return group[:ready_check] if VMS.group_leader?
    return VMS.group_of(VMS.get_player(group[:leader]))&.[](:ready_check)
  end

  # Returns [[name, place, lead text, hp ratio or nil, ready text], ...] for the other members.
  def self.group_hud_entries
    group = VMS.group_data
    check_id = VMS.group_ready_check_id
    entries = []
    group[:members].each do |id|
      next if id == $player.id
      player = VMS.get_player(id)
      name = VMS.group_member_name(id)
      name += _INTL(" (Leader)") if id == group[:leader]
      if player.nil?
        entries.push([name, _INTL("Offline"), "", nil, ""])
        next
      end
      place = (player.map_id == $game_map.map_id) ? _INTL("Nearby") : (pbGetMapNameFromId(player.map_id) rescue "???")
      lead = (player.party || []).find { |pkmn| pkmn && !pkmn.egg? }
      lead_text = lead ? _INTL("{1} Lv.{2}", lead.name, lead.level) : ""
      hp = (lead && lead.totalhp > 0) ? (lead.hp.to_f / lead.totalhp).round(2) : nil
      ready = ""
      answer = VMS.group_of(player)&.[](:ready_answer)
      if check_id && answer.is_a?(Array) && answer[0] == check_id
        ready = answer[1] ? _INTL("Ready") : _INTL("Not ready")
      end
      entries.push([name, place, lead_text, hp, ready])
    end
    return entries
  end

  def self.rebuild_group_hud(entries)
    VMS.dispose_group_hud
    return if entries.empty?
    width = GROUP_HUD_WIDTH
    height = entries.length * GROUP_HUD_ENTRY_HEIGHT + GROUP_HUD_PAD * 2
    bmp = Bitmap.new(width, height)
    VMS.draw_rounded_rect(bmp, 0, 0, width, height, VMS::CHAT_BOX_RADIUS, Color.new(0, 0, 0, VMS::CHAT_BOX_OPACITY))
    inner = width - GROUP_HUD_PAD * 2
    entries.each_with_index do |(name, place, lead_text, hp, ready), i|
      y = GROUP_HUD_PAD + i * GROUP_HUD_ENTRY_HEIGHT
      bmp.font.size = 16
      VMS.group_hud_text(bmp, GROUP_HUD_PAD, y, inner, 18, name, Color.new(255, 255, 255))
      unless ready.empty?
        color = (ready == _INTL("Ready")) ? Color.new(120, 232, 120) : Color.new(240, 120, 120)
        VMS.group_hud_text(bmp, GROUP_HUD_PAD, y, inner, 18, ready, color, 2)
      end
      bmp.font.size = 14
      VMS.group_hud_text(bmp, GROUP_HUD_PAD, y + 18, inner - 64, 16, "#{lead_text}  #{place}".strip, Color.new(208, 208, 208))
      next if hp.nil?
      bar_x = width - GROUP_HUD_PAD - 56
      bar_y = y + 24
      bmp.fill_rect(bar_x, bar_y, 56, 6, Color.new(64, 64, 64))
      bar_color = (hp > 0.5) ? Color.new(88, 208, 88) : (hp > 0.2) ? Color.new(232, 200, 40) : Color.new(232, 72, 56)
      bmp.fill_rect(bar_x, bar_y, (56 * hp).round, 6, bar_color) if hp > 0
    end
    @group_hud_sprite = Sprite.new
    @group_hud_sprite.bitmap = bmp
    @group_hud_sprite.x = Graphics.width - width - 8
    @group_hud_sprite.y = 8
    @group_hud_sprite.z = 99997
  end

  def self.group_hud_text(bmp, x, y, w, h, text, color, align = 0)
    bmp.font.color = Color.new(0, 0, 0)
    bmp.draw_text(x + 1, y + 1, w, h, text, align)
    bmp.font.color = color
    bmp.draw_text(x, y, w, h, text, align)
  end

  def self.dispose_group_hud
    @group_hud_sprite&.bitmap&.dispose
    @group_hud_sprite&.dispose
    @group_hud_sprite = nil
    @group_hud_entries = nil
  end

  # ====================
  # Group chat
  # ====================
  # The server sends chat to everyone, so group messages carry the group ID and
  # other players' games drop them. (A modified client could still read them.)
  GROUP_CHAT_MARK = "\u0001"

  class << self
    alias vms_group_send_chat_message send_chat_message unless method_defined?(:vms_group_send_chat_message)
    alias vms_group_receive_chat_message receive_chat_message unless method_defined?(:vms_group_receive_chat_message)

    def send_chat_message(text)
      group = VMS.group_data
      return vms_group_send_chat_message(text) unless group && VMS.group_setting(:group_chat)
      return unless VMS::ENABLE_CHAT && VMS.is_connected?
      text = text.to_s.strip
      return if text.empty?
      text = text[0, VMS::CHAT_MAX_MESSAGE_LENGTH]
      VMS.send_message(["chat", {
        VMS::PACKET_KEYS[:cluster_id] => VMS.get_cluster_id,
        VMS::PACKET_KEYS[:id]         => $player.id,
        text: "#{GROUP_CHAT_MARK}#{group[:gid]}#{GROUP_CHAT_MARK}#{text}"
      }])
      VMS.append_chat_message(VMS::GROUP_CHAT_PREFIX + $player.name, text)
    end

    def receive_chat_message(sender_name, text)
      match = text.to_s.match(/\A#{GROUP_CHAT_MARK}(\d+)#{GROUP_CHAT_MARK}(.*)\z/m)
      return vms_group_receive_chat_message(sender_name, text) if match.nil?
      group = VMS.group_data
      return unless group && group[:gid] == match[1].to_i
      vms_group_receive_chat_message(VMS::GROUP_CHAT_PREFIX + sender_name.to_s, match[2])
    end
  end

  # ====================
  # Ready check
  # ====================

  # Leader: asks every member and shows answers live until all reply, BACK, or timeout.
  def self.group_run_ready_check
    group = VMS.group_data
    return unless group && VMS.group_leader?
    others = group[:members] - [$player.id]
    if others.empty?
      VMS.message(_INTL("There are no other members yet."))
      return
    end
    check_id = rand(1000...999999)
    group[:ready_check] = check_id
    msgwindow = pbCreateMessageWindow
    msgwindow.letterbyletter = false
    start_time = Time.now
    answers = {}
    begin
      loop do
        VMS.scene_update
        msgwindow.update
        others.each do |id|
          answer = VMS.group_of(VMS.get_player(id))&.[](:ready_answer)
          answers[id] = answer[1] if answer.is_a?(Array) && answer[0] == check_id
        end
        lines = [_INTL("Ready check (BACK to stop)")]
        others.each do |id|
          status = answers.key?(id) ? (answers[id] ? _INTL("Ready") : _INTL("Not ready")) : "..."
          lines.push("#{VMS.group_member_name(id)}: #{status}")
        end
        msgwindow.setText(lines.join("\n"))
        break if answers.length == others.length
        break if Input.trigger?(Input::BACK)
        break if Time.now - start_time > VMS::GROUP_READY_CHECK_TIMEOUT
      end
    ensure
      pbDisposeMessageWindow(msgwindow)
      current = VMS.group_data
      current[:ready_check] = nil if current
    end
    not_ready = others.reject { |id| answers[id] }.map { |id| VMS.group_member_name(id) }
    if not_ready.empty?
      VMS.message(VMS::GROUP_READY_ALL_MESSAGE)
    else
      VMS.message(_INTL(VMS::GROUP_READY_NOT_MESSAGE, not_ready.join(", ")))
    end
  end

  # Member: answers the leader's ready check once, when free on the map.
  def self.group_check_ready_prompt
    group = VMS.group_data
    return unless group && group[:confirmed]
    check_id = VMS.group_ready_check_id
    return if check_id.nil?
    return if group[:ready_answer].is_a?(Array) && group[:ready_answer][0] == check_id
    ready = pbConfirmMessage(_INTL(VMS::GROUP_READY_ASK_MESSAGE, VMS.group_member_name(group[:leader])))
    current = VMS.group_data
    current[:ready_answer] = [check_id, ready] if current
  end
end
