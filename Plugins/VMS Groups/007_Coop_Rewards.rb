#===============================================================================
# Co-op battle rewards: items, catching, Exp/EVs and Pokédex entries.
#
# Both games simulate the whole battle, so a caught Pokémon ends up "caught" on
# both. Each game only keeps the ones its own player threw the ball for.
#
# Exp is worked out during the battle (which foes fainted, and which of your own
# Pokémon fought them) but only handed out afterwards, on each player's own game,
# for their own Pokémon. Levelling up mid-battle would change stats and possibly
# moves on one game only, which would put the two battles out of step.
#===============================================================================
class Battle
  attr_reader :vms_coop_exp_records

  alias vms_coop_pbItemMenu pbItemMenu unless method_defined?(:vms_coop_pbItemMenu)
  alias vms_coop_pbUsePokeBallInBattle pbUsePokeBallInBattle unless method_defined?(:vms_coop_pbUsePokeBallInBattle)
  alias vms_coop_pbRecordAndStoreCaughtPokemon pbRecordAndStoreCaughtPokemon unless method_defined?(:vms_coop_pbRecordAndStoreCaughtPokemon)
  alias vms_coop_pbGainExp pbGainExp unless method_defined?(:vms_coop_pbGainExp)
  alias vms_coop_pbSetSeen pbSetSeen unless method_defined?(:vms_coop_pbSetSeen)

  # Co-op battles aren't "internal" (that would turn on obedience checks and other
  # things that roll dice on one game only), so the Bag is unlocked just for its menu.
  def pbItemMenu(idxBattler, firstAction)
    return vms_coop_pbItemMenu(idxBattler, firstAction) if !@vms_coop || !VMS::COOP_ALLOW_ITEMS
    @internalBattle = true
    begin
      return vms_coop_pbItemMenu(idxBattler, firstAction)
    ensure
      @internalBattle = false
    end
  end

  # Remembers which player threw the ball for each Pokémon caught.
  def pbUsePokeBallInBattle(item, idxBattler, userBattler)
    return vms_coop_pbUsePokeBallInBattle(item, idxBattler, userBattler) if !@vms_coop
    caught_before = @caughtPokemon.length
    vms_coop_pbUsePokeBallInBattle(item, idxBattler, userBattler)
    thrower = pbGetOwnerIndexFromBattlerIndex(userBattler.index)
    @vms_coop_catches ||= {}
    @caughtPokemon[caught_before..].each { |pkmn| @vms_coop_catches[pkmn.object_id] = thrower }
  end

  # Keeps only this player's catches, and stores them with this player as the owner.
  def pbRecordAndStoreCaughtPokemon
    return vms_coop_pbRecordAndStoreCaughtPokemon if !@vms_coop
    catches = @vms_coop_catches || {}
    @caughtPokemon.select! { |pkmn| catches[pkmn.object_id] == @vms_coop[:owner] }
    @caughtPokemon.each do |pkmn|
      # Wild Pokémon were generated on the host's game, so they start out as the host's
      pkmn.owner = Pokemon::Owner.new_from_trainer($player) if !pkmn.shadowPokemon?
    end
    # Storing uses pbPlayer, which is the host on the guest's game
    real_players = @player
    @player = [$player] + real_players.reject { |t| t.equal?($player) }
    begin
      vms_coop_pbRecordAndStoreCaughtPokemon
    ensure
      @player = real_players
    end
  end

  # The original stops early because co-op battles aren't internal; just note what
  # was defeated so Exp can be given out after the battle.
  def pbGainExp
    vms_coop_pbGainExp
    vms_coop_record_exp if @vms_coop && VMS::COOP_EXP
  end

  def vms_coop_record_exp
    @vms_coop_exp_records ||= []
    @vms_coop_exp_done ||= {}
    owner = @vms_coop[:owner]
    party = pbParty(0)
    first = @party1starts[owner]
    last = @party1starts[owner + 1] || party.length
    @battlers.each do |b|
      next unless b&.opposes?
      # A caught Pokémon's slot is cleared right after its own Exp is handed out
      next if !b.pokemon || b.participants.empty?
      next unless b.fainted? || b.captured
      next if @vms_coop_exp_done[b.pokemon.object_id]
      @vms_coop_exp_done[b.pokemon.object_id] = true
      fought = b.participants.select { |i| i >= first && i < last && party[i]&.able? }.map { |i| i - first }
      @vms_coop_exp_records.push({
        level:    b.level,
        base_exp: b.pokemon.base_exp,
        ev_yield: b.pokemon.evYield.dup,
        fought:   fought.uniq,
        trainer:  trainerBattle?
      })
    end
  end

  # The original skips non-internal battles; register each foe as it's sent out.
  # pbPlayer is the host on the guest's game, so this uses $player's own Pokédex.
  def pbSetSeen(battler)
    return vms_coop_pbSetSeen(battler) if !@vms_coop
    return if !battler
    if battler.is_a?(Battler)
      $player.pokedex.register(battler.displaySpecies, battler.displayGender,
                               battler.displayForm, battler.shiny?)
    else
      $player.pokedex.register(battler)
    end
  end
end

module VMS
  # Gives Exp/EVs to this player's own Pokémon (party = the ones they brought).
  def self.coop_award_exp(records, party)
    return if records.nil? || records.empty?
    exp_all = $player.has_exp_all || $bag.has?(:EXPALL)
    gains = Array.new(party.length, 0)
    records.each do |record|
      party.each_with_index do |pkmn, i|
        next if !pkmn || pkmn.egg?
        fought = record[:fought].include?(i)
        # Pokémon that fought were able to when the foe fainted, so they still count
        next if !fought && (!exp_all || !pkmn.able?)
        VMS.coop_gain_evs(pkmn, record[:ev_yield])
        gains[i] += VMS.coop_exp_amount(pkmn, record, fought)
      end
    end
    party.each_with_index { |pkmn, i| VMS.coop_gain_exp(pkmn, gains[i]) if pkmn && gains[i] > 0 }
  end

  # Same formula as Battle#pbGainExpOne (without the Exp Share item).
  def self.coop_exp_amount(pkmn, record, fought)
    level = record[:level]
    base = level * record[:base_exp]
    if fought
      exp = base / (Settings::SPLIT_EXP_BETWEEN_GAINERS ? [record[:fought].length, 1].max : 1)
    else
      exp = base / 2   # Exp All
    end
    return 0 if exp <= 0
    exp = (exp * 1.5).floor if Settings::MORE_EXP_FROM_TRAINER_POKEMON && record[:trainer]
    if Settings::SCALED_EXP_FORMULA
      exp /= 5
      level_adjust = ((2 * level) + 10.0) / (pkmn.level + level + 10.0)
      level_adjust = Math.sqrt(level_adjust**5)
      exp = (exp * level_adjust).floor
      exp += 1 if fought
    else
      exp /= 7
    end
    if pkmn.owner.id != $player.id ||
       (pkmn.owner.language != 0 && pkmn.owner.language != $player.language)
      foreign_language = pkmn.owner.language != 0 && pkmn.owner.language != $player.language
      exp = (exp * (foreign_language ? 1.7 : 1.5)).floor
    end
    exp = exp * 3 / 2 if pkmn.hasItem?(:LUCKYEGG)
    return exp
  end

  # Same as Battle#pbGainEVsOne for a normal (non-Shadow) Pokémon.
  def self.coop_gain_evs(pkmn, ev_yield)
    return if pkmn.shadowPokemon?
    ev_yield = ev_yield.dup
    Battle::ItemEffects.triggerEVGainModifier(pkmn.item, pkmn, ev_yield)
    ev_yield.each_key { |stat| ev_yield[stat] *= 2 } if pkmn.pokerusStage >= 1
    ev_total = 0
    GameData::Stat.each_main { |s| ev_total += pkmn.ev[s.id] }
    GameData::Stat.each_main do |s|
      gain = (ev_yield[s.id] || 0).clamp(0, Pokemon::EV_STAT_LIMIT - pkmn.ev[s.id])
      gain = gain.clamp(0, Pokemon::EV_LIMIT - ev_total)
      pkmn.ev[s.id] += gain
      ev_total += gain
    end
    pkmn.calc_stats
  end

  # Adds Exp with the usual messages, level-ups and new moves.
  def self.coop_gain_exp(pkmn, amount)
    new_exp = [pkmn.exp + amount, pkmn.growth_rate.maximum_exp].min
    gained = new_exp - pkmn.exp
    return if gained <= 0
    old_level = pkmn.level
    pkmn.exp = new_exp
    pkmn.calc_stats
    pbMessage(_INTL("{1} gained {2} Exp. Points!", pkmn.name, gained.to_s_formatted))
    new_level = pkmn.level
    return if new_level <= old_level
    (new_level - old_level).times { pkmn.changeHappiness("levelup") }
    pbMessage(_INTL("{1} grew to Lv. {2}!", pkmn.name, new_level) + "\\me[Pkmn level up]")
    moves = pkmn.getMoveList
    ((old_level + 1)..new_level).each do |level|
      moves.each { |move_level, move| pbLearnMove(pkmn, move, true) if move_level == level }
    end
  end
end
