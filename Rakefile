# ZMK firmware tasks.
#
#   rake setup        initialize the west workspace (runs on devcontainer create)
#   rake update       pull in changes to config/west.yml
#   rake build        build every entry in build.yaml into build/
#   rake "build[board,shield]"  build a single board (shield optional)
#   rake flash        flash a keyboard's halves with its firmware from build/
#   rake flash:reset  flash a keyboard's halves with settings_reset firmware
#
# setup, update and build run inside the devcontainer. flash runs on the host,
# where the bootloader volumes mount; it sticks to Ruby 2.6 (macOS system Ruby).
#
# Environment:
#   ZMK_WORKSPACE   west workspace (default: /opt/zmk-workspace)
#   FIRMWARE_DIR    directory holding the .uf2 files (default: ./build)
#   LEFT_VOLUME     bootloader volume name of the left half
#   RIGHT_VOLUME    bootloader volume name of the right half
#                   Without a name, any mounted volume containing INFO_UF2.TXT is used.
#   WAIT_TIMEOUT    seconds to wait for a bootloader volume (default: 120)

require "fileutils"
require "shellwords"
require "tmpdir"
require "yaml"

REPO_DIR = File.expand_path(__dir__)
WORKSPACE = ENV.fetch("ZMK_WORKSPACE", "/opt/zmk-workspace")
BUILD_YAML = File.join(REPO_DIR, "build.yaml")
FIRMWARE_DIR = File.expand_path(ENV.fetch("FIRMWARE_DIR", File.join(REPO_DIR, "build")))

# One entry per build.yaml include. The name mirrors the GitHub workflow:
# artifact-name, or "<shield>-<board>" when no artifact-name is given.
Build = Struct.new(:board, :shield, :artifact, :snippet, :cmake_args) do
  def name
    return artifact unless artifact.empty?
    shield.empty? ? board : "#{shield}-#{board}"
  end

  def settings_reset?
    shield == "settings_reset"
  end

  def half
    [board, name].each do |s|
      return "left" if s.end_with?("_left")
      return "right" if s.end_with?("_right")
    end
    "single"
  end

  # Groups the halves of one keyboard.
  def key
    name.sub(/_(left|right)\z/, "")
  end
end

def builds
  data = YAML.safe_load(File.read(BUILD_YAML)) || {}
  (data["include"] || []).map do |item|
    Build.new(*%w[board shield artifact-name snippet cmake-args].map { |k| item[k].to_s.strip })
  end
end

# Copy rather than symlink: west resolves symlinks when locating the workspace
# root, so a symlinked config/ would make it treat the bind-mounted repo itself
# as the west topdir and collide with its own zephyr/ directory.
def sync_config
  FileUtils.mkdir_p(WORKSPACE)
  FileUtils.rm_rf(File.join(WORKSPACE, "config"))
  FileUtils.cp_r(File.join(REPO_DIR, "config"), File.join(WORKSPACE, "config"))
end

# west zephyr-export writes to $HOME/.cmake/packages, which lives on the
# container's root filesystem rather than the persisted workspace volume, so it
# must be re-run on every container (re)creation, not just on first init.
def zephyr_export
  Dir.chdir(WORKSPACE) { sh "west", "zephyr-export" }
end

def workspace_initialized?
  File.directory?(File.join(WORKSPACE, "zmk"))
end

desc "Initialize the ZMK west workspace"
task :setup do
  sync_config
  if workspace_initialized?
    puts "ZMK workspace already initialized at #{WORKSPACE}"
    puts "Run `rake update` to pull in changes to config/west.yml"
  else
    Dir.chdir(WORKSPACE) do
      sh "west", "init", "-l", "config"
      sh "west", "update"
    end
    puts "ZMK workspace initialized at #{WORKSPACE}"
  end
  zephyr_export
end

desc "Update the west workspace to match config/west.yml"
task :update do
  next Rake::Task[:setup].invoke unless workspace_initialized?
  sync_config
  Dir.chdir(WORKSPACE) { sh "west", "update" }
  zephyr_export
end

def build_one(build)
  puts "==> Building #{build.name} (board=#{build.board}#{", shield=#{build.shield}" unless build.shield.empty?})"

  cmake_args = ["-DZMK_CONFIG=#{WORKSPACE}/config", "-DZMK_EXTRA_MODULES=#{REPO_DIR}"]
  cmake_args << "-DSHIELD=#{build.shield}" unless build.shield.empty?
  cmake_args.concat(Shellwords.split(build.cmake_args))
  west_args = build.snippet.empty? ? [] : ["-S", build.snippet]

  Dir.mktmpdir do |build_dir|
    Dir.chdir(WORKSPACE) do
      sh "west", "build", "-s", "zmk/app", "-d", build_dir, "-b", build.board, *west_args, "--", *cmake_args
    end

    uf2 = File.join(build_dir, "zephyr", "zmk.uf2")
    if File.file?(uf2)
      FileUtils.cp(uf2, File.join(FIRMWARE_DIR, "#{build.name}.uf2"))
      puts "==> Firmware ready: build/#{build.name}.uf2"
    else
      warn "==> No .uf2 produced for #{build.name} -- check the build log above"
    end
  end
end

desc "Build firmware for every build.yaml entry, or for one board (and shield)"
task :build, [:board, :shield] => :setup do |_, args|
  FileUtils.mkdir_p(FIRMWARE_DIR)
  targets = if args[:board]
              [Build.new(args[:board], args[:shield].to_s, "", "", "")]
            else
              builds
            end
  targets.each { |b| build_one(b) }
end

# --- flashing ---------------------------------------------------------------

WAIT_TIMEOUT = Integer(ENV.fetch("WAIT_TIMEOUT", "120"))
MOUNT_ROOTS = ["/Volumes", ("/media/#{ENV['USER']}" if ENV["USER"]),
               ("/run/media/#{ENV['USER']}" if ENV["USER"]), "/media"].compact

def volume_label(vol)
  vol.to_s.empty? ? "any UF2 bootloader volume" : vol
end

# The mount point of the bootloader volume: the one named vol, or, when vol is
# empty, the first volume that has the UF2 bootloader's INFO_UF2.TXT.
def volume_path(vol)
  MOUNT_ROOTS.each do |root|
    next unless File.directory?(root)
    if vol.to_s.empty?
      info = Dir.glob(File.join(root, "*", "INFO_UF2.TXT")).first
      return File.dirname(info) if info
    else
      path = File.join(root, vol)
      return path if File.directory?(path)
    end
  end
  nil
end

def wait_for_volume(vol)
  WAIT_TIMEOUT.times do
    path = volume_path(vol)
    if path
      puts
      return path
    end
    print "."
    $stdout.flush
    sleep 1
  end
  puts
  abort "Timed out after #{WAIT_TIMEOUT}s waiting for #{volume_label(vol)} (looked in: #{MOUNT_ROOTS.join(' ')})."
end

# The bootloader reboots as soon as it has the image, so wait for the mount to
# go away before continuing (both halves often share the same volume name).
def wait_for_unmount(mount)
  30.times do
    break unless File.directory?(mount)
    sleep 1
  end
end

def prompt(message)
  print message
  $stdout.flush
  ($stdin.gets || "").strip
end

def flash_half(half, file, vol)
  puts
  puts "=== #{half} half: #{File.basename(file)} -> #{volume_label(vol)}"
  mount = volume_path(vol)
  if mount
    puts "A bootloader volume is already mounted at #{mount}."
    unless prompt("Is that the #{half} half? [y/N] ") =~ /\Ay/i
      abort "Eject it (or unplug it) first, then re-run."
    end
  else
    prompt("Connect the #{half} half over USB and double-tap its reset button, then press Enter... ")
    print "Waiting for #{volume_label(vol)}"
    mount = wait_for_volume(vol)
  end

  puts "Copying to #{mount} ..."
  begin
    FileUtils.cp(file, mount)
  rescue SystemCallError
    # The device may reboot before the copy finishes closing the file, which
    # raises even though the flash succeeded.
    puts "(copy reported an error; this is normal if the board rebooted right away)"
  end
  system("sync")
  wait_for_unmount(mount)
  puts "#{half} half flashed."
end

def choose_keyboard(candidates)
  keys = candidates.map(&:key).uniq
  keys.each_with_index do |key, i|
    shield = candidates.find { |b| b.key == key }.shield
    puts "#{i + 1}) #{key}#{"  [shield: #{shield}]" unless shield.empty?}"
  end
  loop do
    choice = prompt("Select keyboard: ")
    abort "No keyboard selected." if choice.empty? && $stdin.eof?
    index = choice.to_i if choice =~ /\A\d+\z/
    return keys[index - 1] if index && index.between?(1, keys.size)
    puts "Invalid choice."
  end
end

def flash(reset:)
  if File.exist?("/.dockerenv") || File.exist?("/run/.containerenv") || ENV["REMOTE_CONTAINERS"]
    warn "Warning: this looks like a container; USB volumes usually only mount on the host."
  end

  candidates = builds.select { |b| b.settings_reset? == reset }
  abort "No matching builds found in #{BUILD_YAML}." if candidates.empty?

  left_vol = ENV["LEFT_VOLUME"].to_s
  right_vol = ENV["RIGHT_VOLUME"].to_s
  puts "Firmware directory: #{FIRMWARE_DIR}"
  puts "Volumes: left=#{volume_label(left_vol)}  right=#{volume_label(right_vol)}"
  puts
  key = choose_keyboard(candidates)

  # Flash left first, then right, then any unsplit build.
  volumes = { "left" => left_vol, "right" => right_vol, "single" => left_vol }
  flashed = 0
  %w[left right single].each do |half|
    build = candidates.find { |b| b.key == key && b.half == half }
    next unless build
    file = File.join(FIRMWARE_DIR, "#{build.name}.uf2")
    abort "Missing #{file} -- build it with `rake build` or download it from GitHub Actions." unless File.file?(file)
    flash_half(half, file, volumes[half])
    flashed += 1
  end

  puts
  puts "Done: flashed #{flashed} half/halves of #{key}."
end

desc "Flash a keyboard's halves with the firmware from build/"
task(:flash) { flash(reset: false) }

namespace :flash do
  desc "Flash a keyboard's halves with the settings_reset firmware"
  task(:reset) { flash(reset: true) }
end
