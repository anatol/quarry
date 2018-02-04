### Rubygems binary packages repository a.k.a Quarry

Quarry is a tool that manages a rubygems binary repository for Arch Linux. The binary packages repository is hosted at http://pkgbuild.com/~anatolik/quarry; currently only 64 bit is supported. If you want to use the quarry repository, add the following lines to */etc/pacman.conf*:

```
[quarry]
Server = http://pkgbuild.com/~anatolik/quarry/x86_64/
````

Unlike packages from the AUR, using the binary repository is better because:
 - installing packages from binary repo is much easier and faster.
 - quarry packs the minimal set of files needed for a user. E.g. rubygems with native extensions contain 3 (three!) copies of the same *.so files, rubygems install a lot of garbage such as test file, readmes, etc..
 - quarry handles dependencies correctly.
 - a new version appears in the Arch repo soon after it is published in rubygems, we are talking about hours latency here.

#### Quarry tool internals

Source code is hosted at github https://github.com/anatol/quarry and released under the GPL3 license.

Quarry manages gems listed in the *whitelist_packages* file, plus all dependencies of these packages. If you want to see your package in the binary repo add it to https://github.com/anatol/quarry/blob/master/whitelist_packages

Converting a gem into a binary Arch package is simple and straightforward for most gems. Some rubygems need additional configuration. This specific information is stored in *config.pkg/$PACKAGE.yaml* config files. These are YAML files with the following fields:

  * **depends** - array of additional dependencies. Quarry extracts ruby dependencies from the gem specification file, but if you want to add native dependencies you should list them here.
  * **makedepends** - array of additional makedepends.
  * **optdepends** - a map of optional dependencies. It has the same structure as PKGBUILD optdepends field - (dependency, description).
  * **include** - by default Quarry copies only *bin* and *lib* gem directories. If you want to copy other files/directories then add them here.
  * **exclude** - exclude the list of directories from the final package. Is useful to exclude default directories such as *lib*. e.g. some gems do not contain directory *lib* despite Rubygem says otherwise. *exclude* property helps Quarry to avoid copying (and failing) such unexistent directories.
  * **rename** - a map of pairs that rename files in /usr/bin/. Most rubygems files are kept in rubygems specific folders under /usr/lib/ruby/gems. But some rubygems create files under /usr/bin and such files can conflict with popular packages. To avoid this we added a mechanism to prevent conflict by renaming files in /usr/bin. This config option is a map of 'from_name: to_name' renames.
  * **gem_install_args** - additional arguments used during the `gem install` step. It can be useful to pass parameters like `--use-system-libraries`

If the slot version has no config then it checks config for a less specific slot. E.g. if there was a slot version *rails-3.2.6* then it would check configs for *rails-3.2.6*, *rails-3.2*, *rails-3*, *rails* until it finds an existing file. 

If a gem requires patching then you can add a $PACKAGE.patch file and it will be applied automatically before installing the gem.

File *rebuild_packages* contains a list of gems to force rebuild with new pkgrel. It might be useful if e.g. configuration for the gem has changed.
