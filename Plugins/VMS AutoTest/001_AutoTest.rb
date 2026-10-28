#===============================================================================
# Automatic two-player test of VMS Groups, using the real game.
#
# Only active when the game is started with the environment variable
# VMS_AUTOTEST set to "host" or "guest" (and the "debug" argument so plugins
# compile). Run one of each on the same PC:
#
#   VMS_AUTOTEST=host  Game.exe debug
#   VMS_AUTOTEST=guest Game.exe debug
#
# Each game skips the title screen, makes a test player, connects to the other
# over the Integrated Server, and runs scripted co-op battles with the AI
# choosing moves on both sides. Every turn is written to
# autotest_logs/<role>.log so the two games can be compared line by line.
# Normal play is unaffected when VMS_AUTOTEST isn't set.
#===============================================================================
module VMS
  module AutoTest
    ROLE = ENV["VMS_AUTOTEST"].to_s.downcase
    ACTIVE = ["host", "guest"].include?(ROLE)
    LOG_DIR = "autotest_logs"
    TIME_LIMIT = 900
    TEST_MAP = 2   # Lappet Town
    PHASE_VAR = :vms_autotest_phase

    module_function

    def host?; ROLE == "host"; end

    def log(text)
      Dir.mkdir(LOG_DIR) if !File.directory?(LOG_DIR)
      File.open(File.join(LOG_DIR, "#{ROLE}.log"), "a") do |f|
        f.write("[#{format('%.1f', Time.now - (@start_time || Time.now))}] #{text}\n")
      end
    end

    def check(label, ok)
      log("#{ok ? 'PASS' : 'FAIL'} #{label}")
    end

    def fake_event?; @fake_event; end

    # Plays the scenario steps as if inside an event (so shared progress waits for it).
    def as_event
      @fake_event = true
      return yield
    ensure
      @fake_event = false
    end

    def wait(seconds)
      start = Time.now
      VMS.scene_update while Time.now - start < seconds
    end

    def wait_until(seconds, label)
      start = Time.now
      loop do
        return true if yield
        if Time.now - start > seconds
          log("TIMEOUT waiting for #{label}")
          return false
        end
        VMS.scene_update
      end
    end

    def other_player
      return VMS.get_players.find { |p| p.id != $player.id }
    end

    # ====================
    # Game setup (replaces the title screen)
    # ====================

    def start_game
      $game_temp.begun_new_game = true
      pbMapInterpreter&.clear
      pbMapInterpreter&.setup(nil, 0, 0)
      $scene = Scene_Map.new
      SaveData.load_new_game_values
      $game_temp.last_uptime_refreshed_play_time = System.uptime
      $map_factory = PokemonMapFactory.new(TEST_MAP)
      $game_player.moveto(host? ? 10 : 12, 12)
      $game_player.refresh
      $PokemonEncounters = PokemonEncounters.new
      $PokemonEncounters.setup($game_map.map_id)
      $game_map.update
      $player.name = host? ? "Host" : "Guest"
      # Silent test runs
      $PokemonSystem.bgmvolume = 0
      $PokemonSystem.sevolume = 0
      $PokemonSystem.textspeed = 3
      $PokemonSystem.battlescene = 1
      $PokemonSystem.givenicknames = 1
      $PokemonSystem.sendtoboxes = 1
      if host?
        pbAddPokemonSilent(:PIKACHU, 14)
        pbAddPokemonSilent(:GEODUDE, 14)
      else
        pbAddPokemonSilent(:BULBASAUR, 14)
        pbAddPokemonSilent(:CHARMANDER, 14)
      end
      $bag.add(:MASTERBALL, 3)
      $bag.add(:POTION, 1)
    end

    # ====================
    # Scenario
    # ====================

    def tick
      return if @running || @finished || !$scene.is_a?(Scene_Map)
      @running = true
      @start_time = Time.now
      begin
        log("=== #{ROLE} started, player id #{$player.id} ===")
        host? ? run_host : run_guest
      rescue SystemExit
        raise
      rescue Exception => e
        log("ERROR #{e.class}: #{e.message}")
        e.backtrace.first(15).each { |line| log("    #{line}") }
      end
      @finished = true
      log("=== #{ROLE} finished ===")
      VMS.leave(false) rescue nil
      exit
    end

    def connect
      VMS.target_host = "127.0.0.1"
      if host?
        VMS::IntegratedServer.start
        wait(1)
      end
      start = Time.now
      until VMS.is_connected? && VMS.get_self
        VMS.join(0) if !VMS.is_connected?
        wait(1)
        raise "could not connect to the server" if Time.now - start > 60
      end
      log("connected")
    end

    def party_summary
      return $player.party.map { |p| "#{p.name} Lv#{p.level} exp=#{p.exp} hp=#{p.hp}/#{p.totalhp}" }.join(", ")
    end

    def run_host
      connect
      return unless wait_until(90, "guest to connect") { other_player }
      guest = other_player
      log("guest seen: #{guest.name} (#{guest.id})")
      VMS.group_create
      wait(1)
      VMS.group_invite(guest)
      ok = wait_until(30, "guest to join group") { VMS.group_data[:members].include?(guest.id) }
      check("guest joined the group", ok)
      return if !ok
      wait(2)

      # --- Test 1: co-op wild battle (guest throws a Master Ball on turn 2) ---
      VMS.set_variable(PHASE_VAR, "wild")
      before = $player.party.map(&:exp)
      log("party before wild: #{party_summary}")
      result = as_event { VMS.coop_wild_battle(:PIDGEY, 10, :RATTATA, 10) }
      log("wild battle result: #{result.inspect}, variable 1 = #{$game_variables[1]}")
      log("party after wild: #{party_summary}")
      check("host's Pokémon gained Exp in the wild battle", $player.party.map(&:exp).zip(before).any? { |a, b| a > b })
      check("host kept no caught Pokémon (guest threw the ball)", $player.party.length == 2)
      wait(3)

      # --- Test 2: story battle (auto co-op) plus shared rewards ---
      VMS.set_variable(PHASE_VAR, "story")
      VMS.set_group_setting(:coop_story, true)
      setBattleRule("canLose")
      result = as_event do
        # start_core directly: TrainerBattle.start looks up the calling event, and there is none here
        won = (TrainerBattle.start_core(:YOUNGSTER, "Ben") == 1)
        # What a gym event would do after winning
        $player.badges[0] = true
        $game_switches[60] = true
        $bag.add(:POTION, 2)
        won
      end
      log("story battle won: #{result.inspect}, money #{$player.money}")
      sent = wait_until(30, "partner to confirm shared progress") do
        g = VMS.group_data
        g && g[:progress].nil? && !$game_temp.vms[:coop_progress]
      end
      check("shared progress was sent and confirmed", sent)

      VMS.set_variable(PHASE_VAR, "done")
      wait(5)
    end

    def run_guest
      connect
      ok = wait_until(90, "group invite") { VMS.group_data && VMS.group_data[:confirmed] }
      check("joined the host's group", ok)
      return if !ok
      before = $player.party.map(&:exp)
      log("party before: #{party_summary}")
      wait_until(TIME_LIMIT - 120, "host to finish") { VMS.get_variable(PHASE_VAR) == "done" }
      log("party after: #{party_summary}")
      caught = $player.party.drop(2)
      check("guest kept the Pokémon caught with the Master Ball", caught.length == 1)
      caught.each do |pkmn|
        check("caught #{pkmn.name} belongs to the guest", pkmn.owner.id == $player.id)
      end
      check("guest's own Pokémon gained Exp", $player.party.first(2).map(&:exp).zip(before).any? { |a, b| a > b })
      check("Master Ball used from guest's Bag", $bag.quantity(:MASTERBALL) == 2)
      check("shared badge received", $player.badges[0] == true)
      check("shared switch received", $game_switches[60] == true)
      check("shared items received (1 + 2 Potions)", $bag.quantity(:POTION) == 3)
      check("battle result variable 1 not overwritten", $game_variables[1] == 0)
    end
  end
end

if VMS::AutoTest::ACTIVE
  # Skip the title screen
  def pbCallTitle
    VMS::AutoTest.start_game
    return $scene
  end

  # Press USE now and then while a message, battle or menu is waiting, so nothing needs a person
  module Input
    class << self
      alias vms_autotest_trigger? trigger? unless method_defined?(:vms_autotest_trigger?)
      def trigger?(button)
        if button == Input::USE && Graphics.frame_count % 3 == 0 && $game_temp &&
           ($game_temp.message_window_showing || $game_temp.in_battle || $game_temp.in_menu)
          return true
        end
        return vms_autotest_trigger?(button)
      end
    end
  end

  alias vms_autotest_pbMapInterpreterRunning? pbMapInterpreterRunning?
  def pbMapInterpreterRunning?
    return true if VMS::AutoTest.fake_event?
    return vms_autotest_pbMapInterpreterRunning?
  end

  module VMS
    class << self
      alias vms_autotest_log log
      def log(message = "", warning = false)
        VMS::AutoTest.log("vms: #{message}")
        vms_autotest_log(message, warning)
      end

      alias vms_autotest_coop_restore_party coop_restore_party
      def coop_restore_party(old_party, battle_party)
        VMS::AutoTest.log("restore party: battle party now #{$player.party.map(&:name).inspect}")
        vms_autotest_coop_restore_party(old_party, battle_party)
        VMS::AutoTest.log("restored: #{$player.party.map(&:name).inspect}")
      end

      # Bring the first Pokémon (up to the co-op size) instead of opening the party screen
      def coop_choose_party
        return $player.party.select(&:able?).first(VMS::COOP_PARTY_SIZE)
      end
    end
  end

  class Battle
    alias vms_autotest_pbStartBattle pbStartBattle
    def pbStartBattle
      @controlPlayer = true if @vms_coop   # AI picks moves for both players
      VMS::AutoTest.log("battle #{VMS.coop_context&.[](:bid)} start, seed #{$game_temp.vms[:seed]}, owner #{@vms_coop&.[](:owner)}")
      ret = vms_autotest_pbStartBattle
      VMS::AutoTest.log("battle end decision=#{@decision}")
      return ret
    end

    alias vms_autotest_pbRecordAndStoreCaughtPokemon pbRecordAndStoreCaughtPokemon
    def pbRecordAndStoreCaughtPokemon
      VMS::AutoTest.log("store caught: #{@caughtPokemon.map(&:name).inspect}, tags #{(@vms_coop_catches || {}).values.inspect}, party #{$player.party.length}")
      vms_autotest_pbRecordAndStoreCaughtPokemon
      VMS::AutoTest.log("after store: party #{$player.party.map(&:name).inspect}")
    end

    alias vms_autotest_pbAttackPhase pbAttackPhase
    def pbAttackPhase
      if @vms_coop
        picks = @choices.each_with_index.map { |c, i| "#{i}:#{c[0]}/#{c[1]}/#{c[3]}" }
        VMS::AutoTest.log("SYNC T#{@turnCount} choices #{picks.join(' ')}")
      end
      vms_autotest_pbAttackPhase
    end

    alias vms_autotest_pbEndOfRoundPhase pbEndOfRoundPhase
    def pbEndOfRoundPhase
      vms_autotest_pbEndOfRoundPhase
      return if !@vms_coop
      state = @battlers.each_with_index.map do |b, i|
        b ? "#{i}:#{b.species}:#{b.hp}/#{b.totalhp}:#{b.status}" : "#{i}:-"
      end
      VMS::AutoTest.log("SYNC T#{@turnCount} after #{state.join(' ')} weather=#{@field.weather}")
    end
  end

  # The guest throws a Master Ball at the first foe on the first turn of the wild battle
  class Battle::VMS_CoopAI
    alias vms_autotest_pbDefaultChooseEnemyCommand pbDefaultChooseEnemyCommand
    def pbDefaultChooseEnemyCommand(idxBattler)
      ctx = VMS.coop_context
      if ctx && !VMS::AutoTest.host? && idxBattler == ctx[:my_index] &&
         @battle.wildBattle? && @battle.turnCount == 0 && @battle.battlers[1] && !@battle.battlers[1].fainted?
        VMS::AutoTest.log("throwing Master Ball at battler 1")
        @battle.pbRegisterItem(idxBattler, :MASTERBALL, 1)
        return
      end
      vms_autotest_pbDefaultChooseEnemyCommand(idxBattler)
    end
  end

  EventHandlers.add(:on_frame_update, :vms_autotest,
    proc { VMS::AutoTest.tick }
  )
end
