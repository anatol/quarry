#!/usr/bin/ruby

require 'digest/sha1'
require 'erubis'
require 'shellwords'
require 'rubygems/name_tuple'
require 'rubygems/package'
require 'rubygems/remote_fetcher'



GEM_SOURCE = Gem::Source.new(Gem.default_sources[0])
QUARRY_DIR = File.expand_path(File.join(File.dirname(__FILE__), '..'))
INDEX_DIR = File.join(QUARRY_DIR, 'index')  # it is where we keep binary packages
REPO_DB_FILE = File.join(INDEX_DIR, 'quarry.db.tar.xz')
CONFIG_PKG_DIR = File.join(QUARRY_DIR, 'config.pkg')
WORK_DIR = File.join(QUARRY_DIR, 'work')
WORK_REPO_DIR = File.join(WORK_DIR, 'repo')
WORK_BUILD_DIR = File.join(WORK_DIR, 'build')

# TODO: choose other directory to avoid file conflicts?
GEM_DIR = Gem.default_dir
GEM_EXTENSION_DIR = File.join(GEM_DIR, 'extensions', Gem::Platform.local.to_s, Gem.extension_api_version)

# gems that conflict with ruby package, 'ruby' already provides it
CONFLICTING_GEMS = %w(rake rdoc)


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
options=(!emptydirs)
source=(https://rubygems.org/downloads/$_gemname-$pkgver.gem)
noextract=($_gemname-$pkgver.gem)
sha1sums=('<%= sha1sum %>')

prepare() {
  if [ -f '<%= CONFIG_PKG_DIR %>'/$_gemname.patch ]; then
    rm -rf $_gemname-$pkgver
    gem unpack $_gemname-$pkgver.gem
    cd $_gemname-$pkgver
    patch -p1 < '<%= CONFIG_PKG_DIR %>'/$_gemname.patch
    gem build $_gemname.gemspec
    mv $_gemname-$pkgver.gem ..
    cd ..
  fi
}

package() {
  local _gemdir="<%= gem_dir %>"
  gem install --ignore-dependencies --no-document --no-user-install -i "$pkgdir/$_gemdir" -n "$pkgdir"/usr/bin $_gemname-$pkgver.gem
  rm "$pkgdir/$_gemdir/cache/$_gemname-$pkgver.gem"
<% for license_file in license_files %>
  install -D -m644 "$pkgdir/$_gemdir/gems/$_gemname-$pkgver/<%= license_file %>" "$pkgdir/usr/share/licenses/$pkgname/<%= license_file %>"
<% end %>
<% if remove_binaries %>
  # non-HEAD version should not install any files in /usr/bin
  rm -r "$pkgdir"/usr/bin/
<% end %>
  local _extdir="$pkgdir/<%= gem_extension_dir %>/$_gemname-$pkgver"
  if [ -d "$_extdir" ]; then
    rm -rf "$_extdir"/*
    touch "$_extdir/gem.build_complete"
  fi
  find "$pkgdir/$_gemdir/gems/$_gemname-$pkgver" -mindepth 1 -maxdepth 1 <%= required_dirs.map{|d| '! -name ' + d}.join(' ') %> -exec rm -r {} \\;
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

# Load [name,slot] => [version,pkgver,[dependencies]] for current packages in Arch index
def load_arch_packages
  return {} unless File.exists?(REPO_DB_FILE)

  FileUtils.mkpath(WORK_REPO_DIR)
  `tar xvfJ #{REPO_DB_FILE} -C #{WORK_REPO_DIR}`

  result = {} # [name,slot] => [version,pkgver,[depenedncies]]
  for p in Dir[WORK_REPO_DIR + '/ruby-*'] do
    # parse Arch description file
    desc = IO.readlines(p + '/desc').map(&:strip)
    arch_name = desc[desc.index('%NAME%')+1]
    arch_version = desc[desc.index('%VERSION%')+1]

    key = arch_to_pkg(arch_name)
    fail("Duplicated package exists: #{arch_name}") if result[key]

    if arch_version =~ /^(.*)-(\d+)$/
      version = $1
      pkgver = $2.to_i
    else
      fail("Package #{arch_name} in repository has incorrect version: #{arch_version}")
    end

    dependencies = IO.readlines(p + '/depends').map(&:strip)
    dependencies = dependencies[dependencies.index('%DEPENDS%')+1..-1]
    enddeps = dependencies.index('')
    dependencies = dependencies[0..enddeps-1] if enddeps

    result[key] = [version, pkgver, dependencies]
  end

  return result
end

def pkg_to_arch(name, slot, with_prefix=true)
  result = with_prefix ? 'ruby-' : ''
  result += name
  result += '-' + slot if slot
  return result
end

# String => [name, slot]
def arch_to_pkg(arch_name)
  if arch_name =~ /^ruby-(.*?)(-([\d\.]+))?$/
    name = $1
    slot = $3
  else
    fail("Package #{arch_name} in repository does not match a ruby package")
  end

  return [name, slot]
end

def load_whitelist_packages()
  result = []
  # TOTHINK: load from config.yaml?
  for l in IO.readlines(File.join(QUARRY_DIR, 'whitelist_packages'))
    # format either 'package' or 'package,slot'
    pkg = l.strip.split(',')
    pkg << nil if pkg.size == 1
    raise AssertionError unless pkg.size == 2

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

def dependency_to_slot(dep)
  index = dep.prerelease? ? @gems_beta : @gems_stable
  all_versions = index[dep.name]
  required_ind = all_versions.rindex{|v| dep.requirement.satisfied_by?(Gem::Version.new(v))}
  fail("Cannot resolve package dependency: #{dep}") unless required_ind

  required_version = all_versions[required_ind]
  next_version = all_versions[required_ind+1]

  # if required version is already the last version, then we don't need a versioned dependency
  return nil unless next_version

  slot = ''
  v1 = required_version.split('.')
  v2 = next_version.split('.')
  v1.zip(v2).each do |p1,p2|
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
  fail("Cannot find gem with name #{name} slot #{slot}") unless versions
  versions = versions.select{|v| v == slot or v.start_with?(slot + '.')} if slot
  fail("Cannot find version for gem #{name} slot #{slot}") if versions.empty?
  return versions.last
end

def init
  @gems_stable = load_gem_index(:released)
  @gems_beta = load_gem_index(:prerelease)

  FileUtils.rm_rf(WORK_DIR)
  FileUtils.mkdir(INDEX_DIR) unless File.directory?(INDEX_DIR)
end

def out_of_date_packages(existing_packages)
  result = []

  # find out-of-date existing packages
  for k,v in existing_packages do
    name,slot = *k
    latest = slot_to_version(name, slot)
    # check if released version diverges from current quarry version
    result << k if latest != v[0]
  end

  return result
end

# Checks existing packages and makes sure that their slot still matches
# gem requirements.
# The slot can be out-of-date if dependency requirement has e.g. ~>2.0 while dependency
# version got bumped to 3.0
def package_with_changed_dependencies(existing_packages, outdated_packages)
  # check if we need to regenerate it in case if versioned deps have changed
  result = []
  for k,v in existing_packages do
    next if outdated_packages.include?(k) # we generate anyway, no need to check its dependencies

    spec = package_spec(k[0], v[0])
    changed_deps = []
    for dependency in spec.runtime_dependencies do
      s = dependency_to_slot(dependency)
      d = [dependency.name, s]
      next unless outdated_packages.include?(d)

      changed_deps << d
    end

    for d in changed_deps
      # some of the package dependencies has changed, we need to make sure their slot number is still the same
      if v[2].include?(d)
        result << k
        break
      end
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
  licenses = spec.licenses.map{|l| Shellwords.escape(l)}
  dependencies = %w(ruby) + spec.runtime_dependencies.map{|d|
    s = dependency_to_slot(d)
    pkg_to_arch(d.name, s)
  }
  if config and config['dependencies']
    dependencies = config['dependencies'] + dependencies
  end
  existing_pkg[2] = dependencies
  filename_arch = spec.extensions.empty? ? 'any' : 'x86_64'
  bin_filename = "#{arch_name}-#{version}-#{pkgver}-#{filename_arch}.pkg.tar.xz"

  # spec.full_require_paths contains too much garbage
  required_dirs = %w(bin lib)
  if config and config['include']
    required_dirs += config['include']
  end

  # In case we generate a non-HEAD version of a package, we should clean /usr/bin
  # as it will conflict with a HEAD version of the package
  # Also remove binaries for conflicting gems.
  remove_binaries = ((not slot.nil? or CONFLICTING_GEMS.include?(name)) and not spec.executables.empty?)

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
    required_dirs: required_dirs,
    remove_binaries: remove_binaries,
    gem_dir: GEM_DIR,
    gem_extension_dir: GEM_EXTENSION_DIR
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
    slot = slot[0..ind-1]
  end
  result << slot
  return result
end

def load_config_file(name, slot)
  slot_ledder(slot).each do |s|
    config_name = File.join(CONFIG_PKG_DIR, name + '-' + s + '.yaml')
    return YAML.load(IO.read(config_name)) if File.exists?(config_name)
  end
  config_name = File.join(CONFIG_PKG_DIR, name + '.yaml')
  return YAML.load(IO.read(config_name)) if File.exists?(config_name)
  return nil
end

# generates PKGBUILD, builds binary package for it, copies to index directory and adds it to the Arch repository
def build_package(name, slot, existing_pkg)
  arch_name = pkg_to_arch(name, slot)
  work_dir = File.join(WORK_BUILD_DIR, arch_name)
  FileUtils.mkpath(work_dir)

  config = load_config_file(name, slot)
  pkgbuild,gem_path,bin_filename = generate_pkgbuild(name, slot, existing_pkg, config)
  Dir.chdir(work_dir) {
    IO.write('PKGBUILD', pkgbuild)
    FileUtils.cp(gem_path, '.')
    `makepkg --install --noconfirm --sign`
    fail("The binary package was not built: #{bin_filename}") unless File.exists?(bin_filename)
    FileUtils.mv(bin_filename, INDEX_DIR)
    FileUtils.mv(bin_filename + '.sig', INDEX_DIR)
  }

  `repo-add #{REPO_DB_FILE} #{File.join(INDEX_DIR, bin_filename)}`
end

def build_packages(packages_to_generate, existing_packages)
  while pkg = packages_to_generate.last do
    version = slot_to_version(*pkg)
    spec = package_spec(pkg[0], version)
    upfront_deps = [] # packages should be processed before 'pkg'
    for d in spec.runtime_dependencies do
      s = dependency_to_slot(d)
      key = [d.name, s]

      if packages_to_generate.include?(key)
        # if dependency has to be generated, do it before 'pkg'
        packages_to_generate.delete(key)
        upfront_deps << key
      elsif not existing_packages[key]
        upfront_deps << key
      end
    end

    unless upfront_deps.empty?
      packages_to_generate += upfront_deps
      next
    end

    packages_to_generate.pop

    existing_packages[pkg] = {} unless existing_packages[pkg] # create a stub for the existing package
    build_package(*pkg, existing_packages[pkg])
  end
end

def rsync
  `rsync -avz --exclude quarry.db.tar.xz.old #{INDEX_DIR}/* celestia:packages/quarry/x86_64/`
end

init()

existing_packages = load_arch_packages()
whitelist_packages = load_whitelist_packages()
outdated_packages = out_of_date_packages(existing_packages)
changed_dep_packages = package_with_changed_dependencies(existing_packages, outdated_packages)

# check if new packages appeared in the 'whitelist_packages' list
packages_to_generate = whitelist_packages - existing_packages.keys + outdated_packages + changed_dep_packages

packages_to_generate.uniq!

build_packages(packages_to_generate, existing_packages)

rsync
