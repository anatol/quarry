require 'digest/sha1'
require 'erubis'
require 'shellwords'
require 'pathname'
require 'rubygems/name_tuple'
require 'rubygems/package'
require 'rubygems/remote_fetcher'

GEM_SOURCE = Gem::Source.new(Gem.default_sources[0])
QUARRY_DIR = File.expand_path(File.join(File.dirname(__FILE__), '..'))
INDEX_DIR = File.join(QUARRY_DIR, 'index')  # it is where we keep binary packages
REPO_DB_FILE = File.join(INDEX_DIR, 'quarry.db.tar.xz')
LASTUPDATE_FILE = File.join(INDEX_DIR, 'lastupdate')
CONFIG_PKG_DIR = File.join(QUARRY_DIR, 'config.pkg')
CONFIG_FILE = File.join(QUARRY_DIR, 'config.yaml')
WORK_DIR = File.join(QUARRY_DIR, 'work')
WORK_REPO_DIR = File.join(WORK_DIR, 'repo')
WORK_BUILD_DIR = File.join(WORK_DIR, 'build')
CHROOT_DIR = File.join(WORK_DIR, 'chroot')
CHROOT_ROOT_DIR = File.join(CHROOT_DIR, 'root')
CHROOT_QUARRY_PATH = '/var/quarry-repo' # path to quarry repository inside the chroot
ARCHITECTURE = `uname -m`.strip

GEM_DIR = Gem.default_dir
GEM_EXTENSION_DIR = File.join(GEM_DIR, 'extensions', Gem::Platform.local.to_s, Gem.extension_api_version)

# gems that already exist as packages in the official repositories, and should not be built again.
# This should be accessed via get_official_packages() to ensure it has been initialized.
official_packages = []

PKGBUILD = %{# Maintainer: Ruby quarry (https://github.com/anatol/quarry)

_gemname=<%= gem_name %>
pkgname=ruby-$_gemname<%= slot %>
pkgver=<%= pkgver %>
pkgrel=<%= pkgrel %>
pkgdesc=<%= description %>
arch=(<%= arch %>)
url=<%= website %>
license=(<%= license %>)
depends=(<%= depends %>)
makedepends=(<%= makedepends.join(' ') if makedepends %>)
optdepends=(<% for k,v in optdepends -%>
  '<%= k %>: <%= v %>'
<% end if optdepends %>
)
options=(!emptydirs)
source=(https://rubygems.org/downloads/$_gemname-$pkgver.gem
    <%= patch_sha ? 'patch' : '' %>
)
noextract=($_gemname-$pkgver.gem)
sha1sums=('<%= sha1sum %>'
    <%= patch_sha ? patch_sha : '' %>
)

prepare() {
<% if patch_sha then %>
  gem unpack $_gemname-$pkgver.gem
  gem spec $_gemname-$pkgver.gem --ruby > $_gemname.gemspec
  cd $_gemname-$pkgver
  patch -p1 < ../patch
  gem build ../$_gemname.gemspec
  mv $_gemname-$pkgver.gem ..
  cd ..
<% end %>

  true
}

package() {
  local _gemdir="<%= gem_dir %>"
  gem install --ignore-dependencies --no-document --no-user-install -i "$pkgdir/$_gemdir" -n "$pkgdir"/usr/bin $_gemname-$pkgver.gem <%= gem_install_args %>
  rm "$pkgdir/$_gemdir/cache/$_gemname-$pkgver.gem"
<% for license_file in license_files %>
  install -D -m644 "$pkgdir/$_gemdir/gems/$_gemname-$pkgver/<%= license_file %>" "$pkgdir/usr/share/licenses/$pkgname/<%= license_file %>"
<% end %>
<% if remove_binaries %>
  # non-HEAD version should not install any files in /usr/bin
  rm -r "$pkgdir"/usr/bin/
<% end %>

  # Preserve library and other required directories. Remove junk that gem installs.
  local _copydir=`mktemp -d -t $_gemname.XXX`
  chmod 755 $_copydir
<% unless preserve_dirs.empty? %>
  (cd "$pkgdir/$_gemdir/gems/$_gemname-$pkgver"/ && cp -r --parents <%= preserve_dirs.join(' ') %> $_copydir)
<% end %>
  rm -rf "$pkgdir/$_gemdir/gems/$_gemname-$pkgver"
  mv $_copydir "$pkgdir/$_gemdir/gems/$_gemname-$pkgver"

<% for from,to in rename %>
  mv "$pkgdir/usr/bin/<%= from %>" "$pkgdir/usr/bin/<%= to %>"
<% end if rename %>
<% if contains_extensions %>
  rm -rf "$pkgdir/<%= gem_extension_dir %>/$_gemname-$pkgver/"
  mkdir -p "$pkgdir/<%= gem_extension_dir %>/$_gemname-$pkgver/"
  touch "$pkgdir/<%= gem_extension_dir %>/$_gemname-$pkgver/gem.build_complete"
<% end %>
}
}

# returns name => [versions]
def load_gem_index(type)
  index = {}
  name = nil
  versions = []
  GEM_SOURCE.load_specs(type).each do |t|
    next unless t.match_platform?
    if t.name != name
      name = t.name
      versions = []
      index[name] = versions
    end
    versions << t.version.to_s
  end

  return index
end

def download_gem(spec)
  Gem::RemoteFetcher.fetcher.download(spec, GEM_SOURCE.uri.to_s)
end

def version_gt(version1, version2)
  Gem::Version.new(version1) > Gem::Version.new(version2)
end

# Load [name,slot] => [version,pkgver,[dependencies],filename] for current packages in Arch index
def load_arch_packages
  return {} unless File.exists?(REPO_DB_FILE)

  `tar xvfJ #{REPO_DB_FILE} -C #{WORK_REPO_DIR}`

  result = {} # [name,slot] => [version,pkgver,[depenedncies]]
  for p in Dir[WORK_REPO_DIR + '/ruby-*']
    # parse Arch description file
    desc = IO.readlines(p + '/desc').map(&:strip)
    arch_name = desc[desc.index('%NAME%') + 1]
    arch_version = desc[desc.index('%VERSION%') + 1]
    arch_filename = desc[desc.index('%FILENAME%') + 1]

    key = arch_to_pkg(arch_name)
    fail("Duplicated package exists: #{arch_name}") if result[key]

    if arch_version =~ /^(.*)-(\d+)$/
      version = $1
      pkgver = $2.to_i
    else
      fail("Package #{arch_name} in repository has incorrect version: #{arch_version}")
    end

    if File.exists?(p + '/depends')
      dependencies = IO.readlines(p + '/depends').map(&:strip)
    else
      # since pacman 5.0 dependencies merged with 'desc' file
      dependencies = desc
    end

    dependencies = dependencies[dependencies.index('%DEPENDS%') + 1..-1]
    enddeps = dependencies.index('')
    dependencies = dependencies[0..enddeps - 1] if enddeps
    dependencies.sort!

    # Rubygems likes to yank (delete) published gems.
    # Let's make sure our package is still valid gem.
    if not gem_exists(key[0], version) and version_gt(version, slot_to_version(*key))
      puts "Gem '#{key[0]}' version '#{version}' is present in Arch index but has been yanked from gem repo. Please update the Arch index to match gem repo."
      next
    end

    result[key] = [version, pkgver, dependencies, arch_filename]
  end

  return result
end

def pkg_to_arch(name, slot, with_prefix = true)
  result = with_prefix ? 'ruby-' : ''
  result += name
  result += '-' + slot if slot
  return result
end

# String => [name, slot]
def arch_to_pkg(arch_name)
  fail("Package name #{arch_name} does not start with ruby- prefix") unless arch_name.start_with?('ruby-')
  name = arch_name[5..-1]
  # check if the name itself exists
  return [name, nil] if @gems_stable[name]

  separator = name.rindex('-')
  fail("Cannot find gem for arch package #{arch_name}") unless separator

  slot = name[separator + 1..-1]
  name = name[0..separator - 1]

  index = prerelease_version?(slot) ? @gems_beta : @gems_stable
  fail("Cannot find gem with name #{name} for arch package #{arch_name}") unless index[name]
  return [name, slot]
end

def get_official_packages
  if official_packages.empty?
    for p in `pacman -Slq extra community | grep ^ruby-`.split(' ')
      official_packages << arch_to_pkg(p)
    end
  end
  return official_packages
end

def load_packages(packages_file, check_existance = true)
  result = []
  filename = File.join(QUARRY_DIR, packages_file)
  return result unless File.exists?(filename)

  for l in IO.readlines(filename)
    # format either 'package' or 'package,slot'
    pkg = l.strip.split(',')
    pkg << nil if pkg.size == 1
    raise "Invalid package version #{l}" unless pkg.size == 2

    result << pkg
  end

  return result
end

def prerelease_version?(version)
  version and version =~ /[a-zA-Z]/
end

# Returns gem spec for given name and version
def package_spec(name, version)
  GEM_SOURCE.fetch_spec(Gem::NameTuple.new(name, version))
end

def matches_ruby(name, version)
  spec = package_spec(name, version)
  rrv = spec.required_ruby_version
  return false unless rrv
  return rrv.satisfied_by? Gem.ruby_version
end

def dependency_to_slot(dep)
  index = @gems_stable
  all_versions = index[dep.name]

  # Note that all_versions might be nil if gem contains no stable releases
  required_ind = all_versions && all_versions.rindex { |v| dep.requirement.satisfied_by?(Gem::Version.new(v)) and matches_ruby(dep.name, v) }
  if not required_ind and dep.prerelease?
    # do the same search but in beta index
    index = @gems_beta
    all_versions = index[dep.name]
    required_ind = all_versions.rindex { |v| dep.requirement.satisfied_by?(Gem::Version.new(v)) and matches_ruby(dep.name, v) }
  end
  fail("Cannot resolve package dependency: #{dep}") unless required_ind

  required_version = all_versions[required_ind]
  next_version = all_versions[required_ind + 1]

  # if found package is beta package then its slot equals to the version
  return required_version if prerelease_version?(required_version)

  # if required version is already the last version, then we don't need a versioned dependency
  return nil unless next_version

  slot = ''
  v1 = required_version.split('.')
  v2 = next_version.split('.')
  v1.zip(v2).each do |p1, p2|
    fail("Cannot generate arch name for dependency #{dep}") unless p1
    slot += p1

    if p1 == p2
      slot += '.'
    else
      break
    end
  end

  return slot
end

# Return latest gem index version that matches package slot
def slot_to_version(name, slot)
  index = prerelease_version?(slot) ? @gems_beta : @gems_stable
  versions = index[name]
  fail("Cannot find gem name for [#{name},#{slot}]") unless versions
  versions = versions.select { |v| v == slot or v.start_with?(slot + '.') } if slot
  fail("Cannot find version for [#{name},#{slot}]") if versions.empty?

  for version in versions.reverse
    next unless matches_ruby(name, version)
    return version
  end
  fail("Cannot find version for [#{name},#{slot}] that match current ruby version")
end

# Checks that given gem [name,version] existst in the gem index
def gem_exists(name, version)
  return true if @gems_stable[name] and @gems_stable[name].include?(version)
  return true if @gems_beta[name] and @gems_beta[name].include?(version)

  return false
end

def ignored_packages
  pkgs = @config['ignored_packages'] if @config
  pkgs = [] if pkgs.nil?

  pkgs.map { |p| [p, nil] }
end

def init
  @gems_stable = load_gem_index(:released)
  @gems_beta = load_gem_index(:prerelease)

  unless File.directory?(INDEX_DIR)
    FileUtils.mkdir(INDEX_DIR)
    `repo-add -s #{REPO_DB_FILE} 2>&1`
  end

  FileUtils.rm_rf(WORK_REPO_DIR)

  FileUtils.mkpath(WORK_DIR)
  FileUtils.mkpath(WORK_REPO_DIR)
  FileUtils.mkpath(CHROOT_DIR)

  unless File.exists?(CHROOT_ROOT_DIR)
    user = ENV['USER']

    # Remove possible cache files left from previous build
    `sudo rm -f /var/cache/pacman/pkg/ruby-*`

    `mkarchroot -C /usr/share/devtools/pacman-extra.conf -M /usr/share/devtools/makepkg-#{ARCHITECTURE}.conf #{CHROOT_ROOT_DIR} base-devel ruby`
    pacman_conf = File.join(CHROOT_ROOT_DIR, 'etc', 'pacman.conf')
    `sudo sh -c 'chmod o+w #{pacman_conf}'`

    open(pacman_conf, 'a') { |f|
      f.puts '[quarry]'
      f.puts "Server = file://#{CHROOT_QUARRY_PATH}"
      f.puts '[options]'
      f.puts "CacheDir = #{CHROOT_QUARRY_PATH}"
    }

    sync_chroot_repo
  end

  @config = YAML.load(IO.read(CONFIG_FILE))
end

def out_of_date_packages(existing_packages)
  result = []

  # find out-of-date existing packages
  for k, v in existing_packages
    name, slot = *k
    latest = slot_to_version(name, slot)
    # check if released version diverges from current quarry version
    result << k if latest != v[0]
  end

  return result
end

# Finds all packages that have incorrect/out-of-date dependencies
# The dependency might be different in case of:
#   - some dependency has bumped version and does not match gem requirement anymore
#   - dependencies in config has been changed
def package_with_changed_dependencies(existing_packages)
  # check if we need to regenerate it in case if versioned deps have changed
  result = []
  for k, v in existing_packages
    name, slot = *k
    spec = package_spec(name, v[0])
    config = load_config_file(name, slot)
    dependencies = generate_dependency_list(spec, config)
    if dependencies != v[2]
      result << k
      # puts "name=#{name} slot=#{slot} has out-of-date packages: existing=#{v[2]} new=#{dependencies}"
    end
  end

  return result
end

def find_license_files(spec)
  # find files called COPYING or LICENSE in the root directory
  license_files = spec.files.select do |f|
    next false if f.index('/')
    next true if f.downcase.index('license')
    next true if f.downcase.index('copying')
    next true if f.downcase.index('copyright')
    false
  end

  return license_files
end

# Maps license names from Rubygems to Arch names
def licenses(spec)
  spec.licenses.map { |l|
    case l
    when 'Apache 2.0' then 'Apache'
    when 'Apache-2.0' then 'Apache'
    else l
    end
  }
end

def calculate_preserved_dirs(spec, config)
  gem_dir = spec.full_gem_path
  # full_require_paths contains absolute path like "/usr/lib/ruby/gems/2.4.0/gems/bson_ext-1.12.5/ext/bson_ext"
  required = spec.full_require_paths.reject { |p| not p.start_with?(gem_dir) }.map { |p| p[gem_dir.length + 1..-1] }

  if config and config['include']
    dup = required & config['include'] # directories come both from gemspec and config
    puts "Following directories already included by gemspec: #{dup}" unless dup.empty?
    required += config['include']
  end

  if config and config['exclude']
    nodir = config['exclude'] - required # directories asked to exclude but do not exist
    puts "Following directories asked to exlude but they do not exists: #{nodir}" unless nodir.empty?
    required -= config['exclude']
  end

  return required
end

def generate_dependency_list(spec, config)
  dependencies = %w(ruby) +
                 spec.runtime_dependencies
                     .map { |d|
                   s = dependency_to_slot(d)
                   pkg_to_arch(d.name, s)
                 }

  if config and config['depends']
    dependencies = config['depends'] + dependencies
  end

  return dependencies.sort.uniq
end

# Returns PKGBUILD content and binary filename to be build
def generate_pkgbuild(name, slot, existing_pkg, config)
  version = slot_to_version(name, slot)
  gem_path = download_gem(package_spec(name, version))
  spec = Gem::Package.new(gem_path).spec
  fail("Version mismatch between gem index and gem spec") if version != spec.version.to_s

  arch_name = pkg_to_arch(name, slot)

  if existing_pkg[0] == version # note that for new packages existing_pkg is an empty hash
    existing_pkg[1] += 1
  else
    existing_pkg[0] = version
    existing_pkg[1] = 1
  end
  pkgver = existing_pkg[1]

  arch = spec.extensions.empty? ? 'any' : 'i686 x86_64'
  sha1sum = Digest::SHA1.file(gem_path).hexdigest
  # TODO: if license is not specified in spec, check HEAD spec, check -beta spec
  licenses = licenses(spec).map { |l| Shellwords.escape(l) }
  dependencies = generate_dependency_list(spec, config)
  existing_pkg[2] = dependencies
  filename_arch = spec.extensions.empty? ? 'any' : ARCHITECTURE
  bin_filename = "#{arch_name}-#{version}-#{pkgver}-#{filename_arch}.pkg.tar.xz"

  patch_file = check_pkg_file(name, slot, 'patch')
  patch_sha = Digest::SHA1.file(patch_file).hexdigest if patch_file

  preserve_dirs = calculate_preserved_dirs(spec, config)

  # In case we generate a non-HEAD version of a package, we should clean /usr/bin
  # as it will conflict with a HEAD version of the package
  # Also remove binaries for conflicting gems.
  unless spec.executables.empty?
    if slot.nil?
      preserve_dirs << spec.bindir
    else
      remove_binaries = true
    end
  end

  optdepends = (config and config['optdepends'])
  makedepends = (config and config['makedepends'])
  rename = (config and config['rename'])
  gem_install_args = (config and config['gem_install_args'])

  # TOTHINK: install binaries into directory other than /usr/bin?
  params = {
    gem_name: name,
    slot: slot ? '-' + slot : '',
    pkgver: version,
    pkgrel: pkgver,  # if existing version has the same version then +1 here
    website: Shellwords.escape(spec.homepage),
    description: Shellwords.escape(spec.summary),
    license: licenses.join(', '),
    arch: arch,
    sha1sum: sha1sum,
    depends: dependencies.join(' '),
    license_files: find_license_files(spec),
    preserve_dirs: preserve_dirs,
    remove_binaries: remove_binaries,
    gem_dir: GEM_DIR,
    gem_extension_dir: GEM_EXTENSION_DIR,
    patch_sha: patch_sha,
    makedepends: makedepends,
    optdepends: optdepends,
    rename: rename,
    gem_install_args: gem_install_args,
    contains_extensions: !spec.extensions.empty?,
  }
  content = Erubis::Eruby.new(PKGBUILD).result(params)

  return content, gem_path, bin_filename
end

# For a given slot (e.g. '3.4.1') returns slots from less generic to more generic (['3.4.5', '3.4', '3'])
def slot_ledder(slot)
  return [] unless slot

  result = []
  while ind = slot.rindex('.')
    result << slot
    slot = slot[0..ind - 1]
  end
  result << slot
  return result
end

def check_pkg_file(name, slot, ext)
  slot_ledder(slot).each do |s|
    config_name = File.join(CONFIG_PKG_DIR, name + '-' + s + '.' + ext)
    return config_name if File.exists?(config_name)
  end
  config_name = File.join(CONFIG_PKG_DIR, name + '.' + ext)
  return config_name if File.exists?(config_name)
  return nil
end

def load_config_file(name, slot)
  config_name = check_pkg_file(name, slot, 'yaml')
  config_name ? YAML.load(IO.read(config_name)) : nil
end

def sync_chroot_repo
  `sudo systemd-nspawn -q --bind-ro=#{INDEX_DIR}:#{CHROOT_QUARRY_PATH} -D #{CHROOT_ROOT_DIR} pacman -Syu --noconfirm`
end

# generates PKGBUILD, builds binary package for it, copies to index directory and adds it to the Arch repository
def build_package(name, slot, existing_pkg)
  arch_name = pkg_to_arch(name, slot, false)
  work_dir = File.join(WORK_BUILD_DIR, arch_name)
  FileUtils.rm_rf(work_dir)
  FileUtils.mkpath(work_dir)

  config = load_config_file(name, slot)
  pkgbuild, gem_path, bin_filename = generate_pkgbuild(name, slot, existing_pkg, config)
  Dir.chdir(work_dir) {
    IO.write('PKGBUILD', pkgbuild)
    FileUtils.cp(gem_path, '.')
    patch_file = check_pkg_file(name, slot, 'patch')
    FileUtils.cp(patch_file, 'patch') if patch_file

    system "makechrootpkg -D #{INDEX_DIR}:#{CHROOT_QUARRY_PATH} -c -r #{CHROOT_DIR}"
    fail("The binary package was not built: #{bin_filename}") unless File.exists?(bin_filename)
    `gpg --batch -b #{bin_filename}`
    FileUtils.mv(bin_filename, INDEX_DIR)
    FileUtils.mv(bin_filename + '.sig', INDEX_DIR)
  }

  `repo-add -s #{REPO_DB_FILE} #{File.join(INDEX_DIR, bin_filename)}`
end

def build_packages(packages_to_generate, existing_packages)
  repo_modified = false

  while pkg = packages_to_generate.last
    version = slot_to_version(*pkg)
    spec = package_spec(pkg[0], version)
    upfront_deps = [] # packages should be processed before 'pkg'
    for d in spec.runtime_dependencies
      s = dependency_to_slot(d)
      key = [d.name, s]

      next if get_official_packages.include?(key)
      if packages_to_generate.include?(key)
        # if dependency has to be generated, do it before 'pkg'
        packages_to_generate.delete(key)
        upfront_deps << key
      elsif not existing_packages[key]
        upfront_deps << key
      end
    end

    # head version should be built before slot version to avoid conflicting files
    key = [pkg[0], nil]
    if pkg[1] and packages_to_generate.include?(key)
      packages_to_generate.delete(key)
      upfront_deps << key
    end

    unless upfront_deps.empty?
      packages_to_generate += upfront_deps
      next
    end

    packages_to_generate.pop

    next if get_official_packages.include?(pkg)

    existing_packages[pkg] = {} unless existing_packages[pkg] # create a stub for the existing package
    build_package(*pkg, existing_packages[pkg])
    repo_modified = true

    # sync to chroot as the next package might require this update
    sync_chroot_repo
  end

  if repo_modified
    IO.write(LASTUPDATE_FILE, File.mtime(REPO_DB_FILE).to_i.to_s)
  end

  return repo_modified
end

def sync_repo_to(dest)
  `rsync -avz --delete --exclude quarry.db.tar.xz.old --exclude quarry.files.tar.xz.old #{INDEX_DIR}/ #{dest}/x86_64/`
  `scp #{LASTUPDATE_FILE} #{dest}/`
end
