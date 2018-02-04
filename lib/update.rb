#!/usr/bin/ruby

$:.unshift File.dirname(__FILE__)
require 'quarry.rb'

init()

existing_packages = load_arch_packages()
whitelist_packages = load_packages('whitelist_packages')
outdated_packages = out_of_date_packages(existing_packages)
changed_dep_packages = package_with_changed_dependencies(existing_packages)
force_rebuild_packages = load_packages('rebuild_packages', false)
ignored_packages = ignored_packages()

# check if new packages appeared in the 'whitelist_packages' list
packages_to_generate = whitelist_packages - existing_packages.keys + outdated_packages + changed_dep_packages + force_rebuild_packages - ignored_packages

packages_to_generate.uniq!

repo_modified = build_packages(packages_to_generate, existing_packages)

sync_repo_to('celestia:packages/quarry/') if repo_modified
