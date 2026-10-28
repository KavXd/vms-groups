# Compiles Plugins/ into Data/PluginScripts.rxdata using Essentials' own PluginManager code.
require "zlib"
Dir.chdir(ARGV[0])
$DEBUG = true
module Console
  def self.method_missing(*); end
end
module Essentials; VERSION = "21.1"; end
class Dir; def self.safe?(p); Dir.exist?(p); end; end
src = File.read("Data/Scripts/001_Technical/002_Files/001_FileTests.rb"); eval(src[/^class Dir.*?^end/m])
def _INTL(s, *a); s; end
def pbMessage(*a); raise a.first.to_s; end
def echoln(*); end
module Compiler
  def self.pbCompilerEachPreppedLine(filename)
    File.readlines(filename, chomp: true).each_with_index do |l, i|
      l = l.sub(/A﻿/, "").sub(/s*#.*$/, "").strip
      yield l, i + 1 unless l.empty?
    end
  end
end
load "Data/Scripts/001_Technical/005_PluginManager.rb"
order, plugins = PluginManager.getPluginOrder
PluginManager.compilePlugins(order, plugins)
data = Marshal.load(File.binread("Data/PluginScripts.rxdata"))
data.each { |name, meta, scripts| puts "#{name} v#{meta[:version]}: #{scripts.map(&:first).join(', ')}" }
