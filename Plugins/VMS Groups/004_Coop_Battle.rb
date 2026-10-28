#===============================================================================
# Co-op battles: two group members on one side against NPC trainers or wild
# Pokémon. Call from an event instead of the usual battle commands:
#
#   VMS.coop_trainer_battle(:YOUNGSTER, "Ben")            (same args as TrainerBattle.start)
#   VMS.coop_wild_battle(:PIDGEY, 5, :RATTATA, 5)         (same args as WildBattle.start)
#
# The player who triggers the event is the host. If no group member is free or
# the invite is declined, the battle happens solo as normal.
#
# How it stays in sync:
# - Both games build the exact same battle: host's Pokémon on battler 0, the
#   guest's on battler 2, with the same seed, foes, weather and backdrop.
# - Each player picks moves for their own battler and sends them to the other.
# - Only the host runs the NPC AI, and sends its choices to the guest.
# - If a player disconnects, the AI takes over their Pokémon and the battle
#   carries on for whoever is left.
#===============================================================================
module VMS
  # Stand-in for a Battle while running prepare_battle on the host, so the
  # host's weather/backdrop/rules can be captured and sent to the guest.
  class CoopFieldRecorder
    attr_reader :values, :rules

    def initialize
      @values = {}
      @rules = {}
    end

    def setBattleMode(mode)
      @values[:battle_mode] = mode
    end

    # Setters record a value; prepare_battle also reads some back (e.g. environment)
    def method_missing(name, *args)
      if name.to_s.end_with?("=") && args.length == 1
        @values[name.to_s.chomp("=").to_sym] = args[0]
        return args[0]
      end
      return @values[name] if args.empty?
      super
    end

    def respond_to_missing?(name, include_private = false)
      return true
    end
  end

  # Values that stay local to each player rather than following the host.
  COOP_LOCAL_FIELD_VALUES = [:battle_mode, :showAnims, :switchStyle, :sendToBoxes, :canLose]

  def self.coop_context
    return nil if $game_temp.nil? || $game_temp.vms.nil?
    return $game_temp.vms[:coop]
  end

  # ====================
  # Event entry points
  # ====================

  # Usage: VMS.coop_trainer_battle(*args) (returns true if the battle was won)
  def self.coop_trainer_battle(*args)
    outcome = VMS.coop_battle(:trainer, args)
    return VMS.coop_without_auto { TrainerBattle.start(*args) } if outcome == :solo
    return outcome == 1
  end

  # Runs a battle without the automatic story/wild co-op invites (e.g. after a decline).
  def self.coop_without_auto
    old = $game_temp.vms[:coop_no_auto]
    $game_temp.vms[:coop_no_auto] = true
    return yield
  ensure
    $game_temp.vms[:coop_no_auto] = old
  end

  # Usage: VMS.coop_wild_battle(*args) (returns false if the battle was lost)
  def self.coop_wild_battle(*args)
    outcome = VMS.coop_battle(:wild, args)
    return WildBattle.start(*args) if outcome == :solo
    return outcome != 2 && outcome != 5
  end

  def self.coop_available?
    return VMS::ENABLE_COOP && VMS.is_connected? && VMS.in_group? &&
           !BattleCreationHelperMethods.skip_battle? &&
           $game_temp.vms[:state].is_a?(Array) && $game_temp.vms[:state][0] == :idle
  end

  # Free group members, nearest first. For automatic invites (mode :wild or :story)
  # only members on the same map within that mode's distance count.
  def self.coop_free_members(mode = nil)
    distance = { wild: VMS::COOP_AUTO_DISTANCE, story: VMS::COOP_STORY_DISTANCE }[mode]
    members = VMS.group_members.select do |p|
      next false if p.busy || !p.state.is_a?(Array) || p.state[0] != :idle
      next true if mode.nil?
      next false if p.map_id != $game_map.map_id
      distance <= 0 || VMS.coop_distance_to(p) <= distance
    end
    return members.sort_by { |p| (p.map_id == $game_map.map_id) ? VMS.coop_distance_to(p) : 9999 }
  end

  def self.coop_distance_to(player)
    return (player.x - $game_player.x).abs + (player.y - $game_player.y).abs
  end

  # Returns the battle outcome, or :solo if the caller should run a normal solo battle.
  # mode: nil for event calls, :wild for random encounters (nearest member is invited
  # without asking the host), :story for automatic trainer battles.
  def self.coop_battle(kind, args, mode = nil)
    return :solo unless VMS.coop_available?
    if kind == :trainer
      foes = TrainerBattle.generate_foes(*args)[0]
      size = (foes.length >= 2 || foes[0].party.length >= 2) ? "double" : "2v1"
    else
      foes = WildBattle.generate_foes(*args)
      return :solo if foes.length > 2
      size = "2v#{foes.length}"
    end
    partner = (mode == :wild) ? VMS.coop_free_members(:wild).first : VMS.coop_pick_partner(mode)
    return :solo if partner.nil?
    recorder = VMS::CoopFieldRecorder.new
    BattleCreationHelperMethods.prepare_battle(recorder)
    payload = {
      kind:   kind,
      foes:   foes,
      size:   size,
      field:  recorder.values.reject { |k, _v| VMS::COOP_LOCAL_FIELD_VALUES.include?(k) },
      rules:  recorder.rules,
      seed:   rand(1000000...9999999)
    }
    # Wild Pokémon are already generated, so a solo fallback must fight these same ones
    args.replace(foes) if kind == :wild
    bid = rand(100000...999999)
    timeout = (mode == :wild) ? VMS::COOP_AUTO_INVITE_TIMEOUT : VMS::COOP_INVITE_TIMEOUT
    parties = VMS.coop_host_handshake(partner, bid, payload, timeout)
    # Automatic battles always go ahead solo; story and encounter battles can't be skipped
    return (VMS::COOP_FALLBACK_SOLO || mode) ? :solo : 0 if parties.nil?
    return VMS.coop_run_battle(:host, partner, bid, payload, parties[0], parties[1])
  end

  def self.coop_pick_partner(mode = nil)
    candidates = VMS.coop_free_members(mode)
    return nil if candidates.empty?
    if candidates.length == 1
      partner = candidates[0]
      return pbConfirmMessage(_INTL(VMS::COOP_CONFIRM_PARTNER_MESSAGE, partner.name)) ? partner : nil
    end
    choice = VMS.message(VMS::COOP_PICK_PARTNER_MESSAGE, candidates.map(&:name) + [VMS::COOP_BATTLE_ALONE], -1)
    return nil if choice.nil? || choice < 0 || choice >= candidates.length
    return candidates[choice]
  end

  def self.coop_foe_description(payload)
    if payload[:kind] == :trainer
      return payload[:foes].map(&:full_name).join(" & ")
    end
    return _INTL("wild {1}", payload[:foes].map(&:name).join(" & "))
  end

  # ====================
  # Handshake (overworld)
  # ====================

  # Shows a waiting message until the block returns non-nil for the partner's state.
  # Returns the block's result, or :gone / :cancel / :timeout.
  def self.coop_await(partner_id, timeout, message, cancellable = true)
    msgwindow = pbCreateMessageWindow
    msgwindow.letterbyletter = false
    msgwindow.setText(message)
    start_time = Time.now
    begin
      loop do
        VMS.scene_update
        msgwindow.update
        partner = VMS.get_player(partner_id)
        return :gone if partner.nil? || !VMS.is_connected?
        result = partner.state.is_a?(Array) ? yield(partner.state) : nil
        return result unless result.nil?
        return :cancel if cancellable && Input.trigger?(Input::BACK)
        return :timeout if timeout && Time.now - start_time > timeout
      end
    ensure
      pbDisposeMessageWindow(msgwindow)
    end
  end

  # Holds a state for a moment so the partner sees it, then goes idle.
  def self.coop_hold_state(state, partner_id, seconds = 1.5)
    $game_temp.vms[:state] = state
    start_time = Time.now
    while Time.now - start_time < seconds
      VMS.scene_update
      break if VMS.get_player(partner_id).nil?
    end
    $game_temp.vms[:state] = [:idle, nil]
  end

  def self.coop_choose_party
    count = [VMS::COOP_PARTY_SIZE, $player.able_pokemon_count].min
    return nil if count < 1
    ruleset = PokemonRuleSet.new
    ruleset.setNumberRange(1, count)
    ruleset.addPokemonRule(AblePokemonRestriction.new)
    new_party = nil
    pbFadeOutIn do
      scene = PokemonParty_Scene.new
      screen = PokemonPartyScreen.new(scene, $player.party)
      new_party = screen.pbPokemonMultipleEntryScreenEx(ruleset)
    end
    return new_party
  end

  # Returns [my_party, partner_party], or nil if the co-op battle won't happen.
  def self.coop_host_handshake(partner, bid, payload, timeout = VMS::COOP_INVITE_TIMEOUT)
    me = $player.id
    $game_temp.vms[:state] = [:coop_invite, partner.id, bid, payload]
    answer = VMS.coop_await(partner.id, timeout, _INTL(VMS::COOP_WAIT_RESPONSE_MESSAGE, partner.name)) do |st|
      next nil unless st[1] == me && st[2] == bid
      next :accept if [:coop_accept, :coop_ready].include?(st[0])
      next :decline if [:coop_decline, :coop_cancel].include?(st[0])
      next nil
    end
    if answer != :accept
      VMS.coop_hold_state([:coop_cancel, partner.id, bid], partner.id) if answer == :cancel
      $game_temp.vms[:state] = [:idle, nil]
      VMS.message(_INTL(VMS::COOP_DECLINED_MESSAGE, partner.name)) unless answer == :cancel
      return nil
    end
    $game_temp.vms[:state] = [:coop_selecting, partner.id, bid]
    my_party = VMS.coop_choose_party
    if my_party.nil?
      VMS.coop_hold_state([:coop_cancel, partner.id, bid], partner.id)
      return nil
    end
    partner_party = VMS.coop_await_ready(partner, bid, my_party)
    return nil if partner_party.nil?
    return [my_party, partner_party]
  end

  # Publishes the chosen party and waits for the partner's. Returns their party or nil.
  def self.coop_await_ready(partner, bid, my_party)
    me = $player.id
    $game_temp.vms[:state] = [:coop_ready, partner.id, bid, my_party]
    result = VMS.coop_await(partner.id, VMS::COOP_SELECTION_TIMEOUT, _INTL(VMS::COOP_WAIT_SELECTION_MESSAGE, partner.name)) do |st|
      if st[1] == me && st[2] == bid
        # The partner may already be in battle before their "ready" state reached us
        next st[3] if st[0] == :coop_ready && st[3].is_a?(Array)
        next st[3][:party] if st[0] == :coop_battle && st[3].is_a?(Hash) && st[3][:party].is_a?(Array)
        next nil if [:coop_invite, :coop_accept, :coop_selecting].include?(st[0])
      end
      next :cancel
    end
    return result if result.is_a?(Array)
    VMS.coop_hold_state([:coop_cancel, partner.id, bid], partner.id) if result != :gone
    $game_temp.vms[:state] = [:idle, nil]
    VMS.message(VMS::COOP_CANCELLED_MESSAGE)
    return nil
  end

  def self.coop_join_as_guest(host, bid, payload)
    me = $player.id
    unless pbConfirmMessage(_INTL(VMS::COOP_INVITE_MESSAGE, host.name, VMS.coop_foe_description(payload)))
      VMS.coop_hold_state([:coop_decline, host.id, bid], host.id)
      return
    end
    $game_temp.vms[:state] = [:coop_accept, host.id, bid]
    my_party = VMS.coop_choose_party
    if my_party.nil?
      VMS.coop_hold_state([:coop_cancel, host.id, bid], host.id)
      return
    end
    host_party = VMS.coop_await_ready(host, bid, my_party)
    return if host_party.nil?
    VMS.coop_run_battle(:guest, host, bid, payload, my_party, host_party)
  end

  # Shows the invite prompt to the guest when they're free on the map.
  def self.coop_frame_update
    return unless VMS::ENABLE_COOP && VMS::ENABLE_GROUPS && VMS.is_connected?
    return unless $scene.is_a?(Scene_Map)
    return if $game_temp.vms[:group_prompting]
    state = $game_temp.vms[:state]
    return unless state.is_a?(Array) && state[0] == :idle
    return unless VMS.interaction_possible?
    group = VMS.group_data
    return if group.nil?
    handled = ($game_temp.vms[:coop_handled] ||= {})
    VMS.get_players.each do |player|
      st = player.state
      next unless st.is_a?(Array) && st[0] == :coop_invite && st[1] == $player.id
      next unless group[:members].include?(player.id)
      next if handled[[player.id, st[2]]]
      handled[[player.id, st[2]]] = true
      $game_temp.vms[:group_prompting] = true
      begin
        VMS.coop_join_as_guest(player, st[2], st[3])
      ensure
        $game_temp.vms[:group_prompting] = false
        $game_temp.vms[:state] = [:idle, nil] if $game_temp.vms[:state][0].to_s.start_with?("coop")
      end
      return
    end
  end

  # ====================
  # Running the battle
  # ====================

  def self.coop_trainer_type(player)
    type = player.trainer_type
    return type if type && GameData::TrainerType.exists?(type)
    return $player.trainer_type
  end

  def self.coop_run_battle(role, partner, bid, payload, my_party, partner_party)
    host = (role == :host)
    old_party = $player.party
    outcome = 0
    ctx = {
      bid:           bid,
      partner_id:    partner.id,
      partner_name:  partner.name,
      role:          role,
      my_index:      host ? 0 : 2,
      partner_index: host ? 2 : 0,
      lost:          false,
      data:          { picks: {}, switches: {}, fled: false, party: my_party }
    }
    begin
      outcome_variable = $game_temp.battle_rules["outcomeVar"] || 1
      can_lose = host ? ($game_temp.battle_rules["canLose"] || false) : !VMS::COOP_GUEST_BLACKS_OUT
      $game_temp.vms[:coop] = ctx
      VMS.coop_publish
      EventHandlers.trigger(:on_start_battle)
      partner_trainer = NPCTrainer.new(partner.name, VMS.coop_trainer_type(partner))
      partner_trainer.party = partner_party
      $player.party = my_party
      host_trainer, guest_trainer = host ? [$player, partner_trainer] : [partner_trainer, $player]
      host_party, guest_party = host ? [my_party, partner_party] : [partner_party, my_party]
      foe_trainers = nil
      if payload[:kind] == :trainer
        foe_trainers = payload[:foes]
        foe_party = []
        foe_starts = []
        foe_trainers.each do |t|
          foe_starts.push(foe_party.length)
          foe_party.concat(t.party)
        end
      else
        foe_party = payload[:foes]
      end
      scene = BattleCreationHelperMethods.create_battle_scene
      battle = Battle.new(scene, host_party + guest_party, foe_party, [host_trainer, guest_trainer], foe_trainers)
      battle.vms_coop = { owner: host ? 0 : 1 }
      battle.battleAI = Battle::VMS_CoopAI.new(battle)
      battle.party1starts = [0, host_party.length]
      battle.ally_items = [[], []]
      if foe_trainers
        battle.party2starts = foe_starts
        battle.items = foe_trainers.map { |t| t.items.clone }
      end
      battle.internalBattle = false
      BattleCreationHelperMethods.prepare_battle(battle)
      $game_temp.clear_battle_rules
      battle.setBattleMode(payload[:size])
      payload[:field].each do |key, value|
        setter = "#{key}="
        battle.send(setter, value) if battle.respond_to?(setter)
      end
      battle.rules.merge!(payload[:rules])
      battle.canLose = can_lose
      battle.switchStyle = false
      battle.disablePokeBalls = !VMS::COOP_ALLOW_CATCHING
      $game_temp.vms[:seed] = payload[:seed]
      srand(payload[:seed])
      VMS.log("Co-op: Starting battle #{bid} as #{role} with #{partner.name}")
      if foe_trainers
        bgm = pbGetTrainerBattleBGM(foe_trainers)
        anim = 3
      else
        bgm = pbGetWildBattleBGM(foe_party)
        anim = (foe_party.length == 1) ? 0 : 2
      end
      pbBattleAnimation(bgm, anim, foe_trainers || foe_party) do
        # Copied first: catches get added to the battle party array itself
        brought = my_party.dup
        pbSceneStandby { outcome = battle.pbStartBattle }
        VMS.coop_restore_party(old_party, brought)
        # Before after_battle, so its evolution check sees any level-ups
        VMS.coop_award_exp(battle.vms_coop_exp_records, brought) if VMS::COOP_EXP
        BattleCreationHelperMethods.after_battle(outcome, can_lose)
      end
      Input.update
      VMS.coop_give_prize_money(foe_trainers) if outcome == 1 && foe_trainers
      BattleCreationHelperMethods.set_outcome(outcome, outcome_variable, !foe_trainers.nil?) if host
      VMS.coop_progress_start(partner.id) if host && outcome == 1 && foe_trainers
    rescue StandardError => e
      VMS.log("Co-op: Error during battle: #{e.message}", true)
      VMS.message(VMS::BASIC_ERROR_MESSAGE)
    ensure
      $player.party = old_party
      VMS.coop_linger(ctx)
      $game_temp.vms[:coop] = nil
      $game_temp.vms[:state] = [:idle, nil]
      VMS.sync_seed
    end
    return outcome
  end

  # Puts the full party back after battle. Pokémon caught during the battle were
  # added to the battle party, so they're moved into the real party (or the PC).
  def self.coop_restore_party(old_party, battle_party)
    caught = $player.party.reject { |pkmn| battle_party.any? { |p| p.equal?(pkmn) } }
    $player.party = old_party
    caught.each do |pkmn|
      if $player.party_full?
        $PokemonStorage.pbStoreCaught(pkmn)
      else
        $player.party.push(pkmn)
      end
    end
  end

  def self.coop_give_prize_money(foe_trainers)
    return unless VMS::COOP_PRIZE_MONEY
    money = 0
    foe_trainers.each do |t|
      max_level = t.party.map { |pkmn| pkmn ? pkmn.level : 0 }.max || 0
      money += max_level * t.base_money
    end
    return if money <= 0
    old_money = $player.money
    $player.money += money
    gained = $player.money - old_money
    pbMessage(_INTL("You got ${1} for winning!", gained.to_s_formatted)) if gained > 0
  end

  # Keeps the final battle data up so a slower partner can still read the last turn.
  def self.coop_linger(ctx)
    $game_temp.vms[:state] = [:coop_done, ctx[:partner_id], ctx[:bid], Marshal.load(Marshal.dump(ctx[:data]))]
    start_time = Time.now
    loop do
      break if Time.now - start_time > VMS::COOP_LINGER_SECONDS
      partner = VMS.get_player(ctx[:partner_id])
      break if partner.nil? || !VMS.is_connected?
      st = partner.state
      break unless st.is_a?(Array) && [:coop_ready, :coop_battle].include?(st[0]) && st[2] == ctx[:bid]
      VMS.scene_update
    end
  end

  # ====================
  # In-battle data exchange
  # ====================

  # Sends this player's battle data (picks/switches) as their VMS state.
  def self.coop_publish
    ctx = VMS.coop_context
    return if ctx.nil?
    $game_temp.vms[:state] = [:coop_battle, ctx[:partner_id], ctx[:bid], Marshal.load(Marshal.dump(ctx[:data]))]
  end

  def self.coop_prune(turn)
    data = VMS.coop_context[:data]
    data[:picks].reject! { |t, _| t < turn - 1 }
    data[:switches].reject! { |key, _| key[0] < turn - 1 }
  end

  def self.coop_publish_pick(battle, idx_battler)
    ctx = VMS.coop_context
    return if ctx.nil? || ctx[:lost]
    turn = battle.turnCount
    VMS.coop_prune(turn)
    (ctx[:data][:picks][turn] ||= {})[idx_battler] = battle.vms_coop_serialize_choice(idx_battler)
    VMS.coop_publish
  end

  def self.coop_publish_switch(key, new_index)
    ctx = VMS.coop_context
    return if ctx.nil? || ctx[:lost]
    VMS.coop_prune(key[0])
    ctx[:data][:switches][key] = new_index
    VMS.coop_publish
  end

  def self.coop_publish_flee
    ctx = VMS.coop_context
    return if ctx.nil? || ctx[:lost]
    ctx[:data][:fled] = true
    VMS.coop_publish
  end

  # Waits in battle until the block returns non-nil for the partner's battle data.
  # Returns the block's result, :fled if the partner ran, or :lost if they're gone.
  def self.coop_battle_wait(battle)
    ctx = VMS.coop_context
    msgwindow = battle.scene.sprites["messageWindow"]
    shown = false
    loop do
      partner = VMS.get_player(ctx[:partner_id])
      st = partner&.state
      waiting_to_start = st.is_a?(Array) && st[0] == :coop_ready && st[2] == ctx[:bid]
      in_battle = st.is_a?(Array) && [:coop_battle, :coop_done].include?(st[0]) &&
                  st[2] == ctx[:bid] && st[3].is_a?(Hash)
      if in_battle
        result = st[3][:fled] ? :fled : yield(st[3])
        if !result.nil?
          msgwindow.visible = false if shown
          msgwindow.setText("") if shown
          return result
        end
      end
      if !VMS.is_connected? || (!in_battle && !waiting_to_start) || (in_battle && st[0] == :coop_done)
        msgwindow.visible = false if shown
        msgwindow.setText("") if shown
        ctx[:lost] = true
        battle.pbDisplayPaused(_INTL(VMS::COOP_PARTNER_LOST_MESSAGE, ctx[:partner_name]))
        return :lost
      end
      if !shown
        battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
        msgwindow.visible = true
        msgwindow.setText(_INTL(VMS::COOP_WAIT_BATTLE_MESSAGE, ctx[:partner_name]))
        battle.scene.pbUpdate(msgwindow) while msgwindow.busy?
        shown = true
      end
      battle.scene.pbUpdate
    end
  end
end

#===============================================================================
# AI: the partner's battler follows the partner, and foes follow the host's AI.
#===============================================================================
class Battle::VMS_CoopAI < Battle::AI
  def pbDefaultChooseEnemyCommand(idxBattler)
    ctx = VMS.coop_context
    return super if ctx.nil? || ctx[:lost]
    # Your own Pokémon under AI control (battle.controlPlayer); published after the player loop
    return super if idxBattler == ctx[:my_index]
    if idxBattler != ctx[:partner_index] && ctx[:role] == :host
      super
      VMS.coop_publish_pick(@battle, idxBattler)
      return
    end
    turn = @battle.turnCount
    entry = VMS.coop_battle_wait(@battle) { |data| data[:picks][turn]&.[](idxBattler) }
    case entry
    when :lost
      super
    when :fled
      @battle.pbDisplayPaused(_INTL(VMS::COOP_PARTNER_FLED_MESSAGE, ctx[:partner_name]))
      @battle.decision = 3
    else
      @battle.vms_coop_apply_choice(idxBattler, entry)
    end
  end

  def pbDefaultChooseNewEnemy(idxBattler)
    ctx = VMS.coop_context
    key = @battle.vms_coop_next_switch_key(idxBattler)
    return super if ctx.nil? || ctx[:lost]
    if idxBattler == ctx[:my_index] || (idxBattler != ctx[:partner_index] && ctx[:role] == :host)
      ret = super
      VMS.coop_publish_switch(key, ret)
      return ret
    end
    ret = VMS.coop_battle_wait(@battle) { |data| data[:switches][key] }
    return super if ret == :lost
    if ret == :fled
      @battle.decision = 3
      return -1
    end
    return ret
  end
end

#===============================================================================
# Battle hooks, only active for co-op battles (battle.vms_coop is set).
#===============================================================================
class Battle
  attr_accessor :vms_coop

  alias vms_coop_pbOwnedByPlayer? pbOwnedByPlayer? unless method_defined?(:vms_coop_pbOwnedByPlayer?)
  alias vms_coop_pbRandom pbRandom unless method_defined?(:vms_coop_pbRandom)
  alias vms_coop_pbRun pbRun unless method_defined?(:vms_coop_pbRun)
  alias vms_coop_pbSwitchInBetween pbSwitchInBetween unless method_defined?(:vms_coop_pbSwitchInBetween)
  alias vms_coop_pbCommandPhaseLoop pbCommandPhaseLoop unless method_defined?(:vms_coop_pbCommandPhaseLoop)
  alias vms_coop_pbAttackPhase pbAttackPhase unless method_defined?(:vms_coop_pbAttackPhase)

  # The guest controls the second player-side trainer, so "owned by player" depends on who you are.
  def pbOwnedByPlayer?(idxBattler)
    return vms_coop_pbOwnedByPlayer?(idxBattler) if !@vms_coop
    return false if opposes?(idxBattler)
    return pbGetOwnerIndexFromBattlerIndex(idxBattler) == @vms_coop[:owner]
  end

  # Same deterministic formula VMS uses for PvP, so both games roll identical numbers.
  def pbRandom(x)
    return vms_coop_pbRandom(x) if !@vms_coop
    @vms_random_calls ||= 0
    @vms_random_calls += 1
    srand($game_temp.vms[:seed].to_i + (@turnCount * 1000) + @vms_random_calls)
    return rand(x)
  end

  # The command phase can roll numbers on one game only (e.g. the host's AI), so the
  # counter restarts when moves actually happen.
  def pbAttackPhase
    @vms_random_calls = 0 if @vms_coop
    vms_coop_pbAttackPhase
  end

  # Running is a shared decision: it ends the battle for both players and never rolls.
  def pbRun(idxBattler, duringBattle = false)
    return vms_coop_pbRun(idxBattler, duringBattle) if !@vms_coop || @battlers[idxBattler].opposes?
    if trainerBattle?
      pbDisplayPaused(_INTL("No! There's no running from a Trainer battle!")) if !duringBattle
      return 0
    end
    return 0 if duringBattle
    if !@canRun
      pbDisplayPaused(_INTL("You can't escape!"))
      return 0
    end
    return 0 if !pbDisplayConfirm(VMS::COOP_RUN_CONFIRM_MESSAGE)
    pbSEPlay("Battle flee")
    pbDisplayPaused(_INTL("You got away safely!"))
    @decision = 3
    return 1
  end

  def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
    return vms_coop_pbSwitchInBetween(idxBattler, checkLaxOnly, canCancel) if !@vms_coop
    if !@controlPlayer && pbOwnedByPlayer?(idxBattler)
      key = vms_coop_next_switch_key(idxBattler)
      new_index = pbPartyScreen(idxBattler, checkLaxOnly, canCancel)
      VMS.coop_publish_switch(key, new_index)
      return new_index
    end
    return @battleAI.pbDefaultChooseNewEnemy(idxBattler)
  end

  def pbCommandPhaseLoop(isPlayer)
    vms_coop_pbCommandPhaseLoop(isPlayer)
    return if !@vms_coop || !isPlayer
    ctx = VMS.coop_context
    return if ctx.nil?
    if @decision == 3
      VMS.coop_publish_flee
    else
      VMS.coop_publish_pick(self, ctx[:my_index])
    end
  end

  # Both games count switches the same way, so [turn, battler, n] names the same switch on each.
  def vms_coop_next_switch_key(idxBattler)
    @vms_coop_switch_counts ||= {}
    counter = [@turnCount, idxBattler]
    @vms_coop_switch_counts[counter] = (@vms_coop_switch_counts[counter] || 0) + 1
    return [@turnCount, idxBattler, @vms_coop_switch_counts[counter]]
  end

  # Optional battle mechanics added by other plugins (e.g. Deluxe Battle Kit).
  VMS_COOP_SPECIAL_ACTIONS = [
    [:@megaEvolution, :pbRegisterMegaEvolution],
    [:@zMove,         :pbRegisterZMove],
    [:@dynamax,       :pbRegisterDynamax],
    [:@terastallize,  :pbRegisterTerastallize]
  ]

  def vms_coop_serialize_choice(idxBattler)
    choice = @choices[idxBattler] || [:None]
    action = case choice[0]
             when :UseMove   then [:UseMove, choice[1], nil, choice[3]]
             when :SwitchOut then [:SwitchOut, choice[1]]
             when :UseItem   then [:UseItem, choice[1], choice[2], choice[3]]
             else                 [choice[0]]
             end
    side = idxBattler & 1
    owner = pbGetOwnerIndexFromBattlerIndex(idxBattler)
    specials = []
    VMS_COOP_SPECIAL_ACTIONS.each do |ivar, register|
      registered = instance_variable_get(ivar)
      next unless registered.is_a?(Array) && registered[side].is_a?(Array)
      specials.push(register) if registered[side][owner] == idxBattler
    end
    return { choice: action, specials: specials }
  end

  def vms_coop_apply_choice(idxBattler, entry)
    action = entry[:choice] || [:None]
    case action[0]
    when :UseMove
      move = (action[1] < 0) ? @struggle : @battlers[idxBattler].moves[action[1]]
      @choices[idxBattler] = [:UseMove, action[1], move, action[3]]
    when :SwitchOut
      @choices[idxBattler] = [:SwitchOut, action[1], nil, -1]
    when :UseItem
      if opposes?(idxBattler)
        pbRegisterItem(idxBattler, action[1], action[2], action[3])   # Uses up the NPC's item here too
      else
        # The partner's item already left the partner's own Bag on their game
        @choices[idxBattler] = [:UseItem, action[1], action[2], action[3]]
      end
    when :Run, :Shift
      @choices[idxBattler] = [action[0], 0, nil, -1]
    end
    (entry[:specials] || []).each do |register|
      send(register, idxBattler) if respond_to?(register)
    end
  end
end

#===============================================================================
# Random encounters (grass, caves, surfing, fishing...) become co-op battles when a
# group member is close by. Roaming Pokémon, the Safari Zone and the Bug Contest
# keep their own battles.
#===============================================================================
class WildBattle
  class << self
    alias vms_coop_start start unless method_defined?(:vms_coop_start)

    def start(*args, can_override: false)
      if !can_override || !VMS.coop_auto_allowed?(:coop_wild) || VMS.coop_free_members(:wild).empty?
        return vms_coop_start(*args, can_override: can_override)
      end
      foe_party = WildBattle.generate_foes(*args)
      if foe_party.length == 1
        handled = [nil]
        EventHandlers.trigger(:on_calling_wild_battle, foe_party[0], handled)
        return handled[0] if !handled[0].nil?
      end
      outcome = VMS.coop_battle(:wild, foe_party, :wild)
      outcome = WildBattle.start_core(*foe_party) if outcome == :solo
      # Used by the Poké Radar to update/break the chain
      if foe_party.length == 1
        EventHandlers.trigger(:on_wild_battle_end, foe_party[0].species, foe_party[0].level, outcome)
      end
      return outcome != 2 && outcome != 5
    end
  end
end

#===============================================================================
# Story battles: with the "Co-op Story Battles" setting on, every trainer battle
# (gyms, rivals, route trainers) offers to bring a group member on the same map.
# Every trainer battle in Essentials goes through TrainerBattle.start_core,
# including double battles where two trainers spot the player at once.
#===============================================================================
class TrainerBattle
  class << self
    alias vms_coop_start_core start_core unless method_defined?(:vms_coop_start_core)

    def start_core(*args)
      if !VMS.coop_auto_allowed?(:coop_story) || VMS.coop_free_members(:story).empty?
        return vms_coop_start_core(*args)
      end
      outcome = VMS.coop_battle(:trainer, args, :story)
      return vms_coop_start_core(*args) if outcome == :solo
      return outcome
    end
  end
end

module VMS
  # Whether an automatic co-op invite may happen now (setting on, connected, in a group, free).
  def self.coop_auto_allowed?(setting)
    return false if $game_temp.nil? || $game_temp.vms.nil? || $game_temp.vms[:coop_no_auto]
    return false if !VMS::ENABLE_COOP || !VMS.group_setting(setting)
    return VMS.coop_available?
  end
end

EventHandlers.add(:on_frame_update, :vms_coop_invites,
  proc { VMS.coop_frame_update }
)
