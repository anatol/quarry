### Rubygems binary packages repository a.k.a Quarry

Quarry is a tool that manages rubygems binary repository for Linux Arch. The binary packages repository hosted at http://pkgbuild.com/~anatolik/quarry, currently only 64 bit is supported. If you want to use the quarry repository add following lines to */etc/pacman.conf* file:

```
[quarry]
Server = http://pkgbuild.com/~anatolik/quarry/x86_64/
````

Unlike packages from AUR using the binary repository is better because:
 - installing packages from binary repo is much easier and faster.
 - quarry packs minimal set of files needed for a user. E.g. rubygems with native extensions contain 3 (three!) copies of the same *.so files, rubygems install a lot of garbage such as test file, readmes, etc..
 - quarry handles dependencies correctly.
 - a new version appears in Arch repo soon after it is published in rubygems, we are talking about hours latency here.

#### Quarry tool internals

Source code is hosted at github https://github.com/anatol/quarry

Quarry manages gems listed in *whitelist_packages* file plus all dependencies of these packages. If you want to see your package in the binary repo add it to https://github.com/anatol/quarry/blob/master/whitelist_packages

Converting a gem into binary Arch package is simple and straighforward for most gems. Some rubygems need additional configuration. This specific information is stored in *config.pkg/$PACKAGE.yaml* config files. These are YAML files with following fields:

  * **dependencies** - array of additional dependencies. Quarry extracts ruby dependencies from gem specification file, but if you want to add native dependencies you should list it here.
  * **include** - by default Quarry copies only *bin* and *lib* gem directories. If you want to copy other files/directories then add it here.

If gem requires patching then you can add $PACKAGE.patch file and it will be applied automatically before installing the gem.