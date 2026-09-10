#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Exercise the #9485/#9618 lifecycle integration on releases without the
# video-wallpaper services alias. These are production JavaScript functions
# with a synchronous Qt test double, not native QObject/PAM/Wayland coverage.
run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const shellSource = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
const registrySource = fs.readFileSync(path.join(root, 'shell/services/PluginRegistry.qml'), 'utf8')
const storeSource = fs.readFileSync(path.join(root, 'shell/services/AuthServiceStore.js'), 'utf8')

function loadFunctions(source, names, context) {
  for (const name of names) {
    const match = source.match(new RegExp(`^  function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?^  \\}`, 'm'))
    if (!match) fail(`production function is present: ${name}`)
    vm.runInContext(match[0], context)
  }
}

function fixture() {
  const store = vm.createContext({})
  vm.runInContext(storeSource, store)
  const registry = vm.createContext({
    Util: { isPlainObject: value => !!value && typeof value === 'object' && !Array.isArray(value) }
  })
  loadFunctions(registrySource, ['trustedCapabilities', 'stampHostCapabilities'], registry)
  const firstParty = {}
  for (const [id, file] of Object.entries({
    'omarchy.lock': 'lock/manifest.json',
    'omarchy.polkit': 'polkit/manifest.json',
    'omarchy.idle': 'services/idle/manifest.json'
  })) {
    firstParty[id] = {
      ...JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins', file), 'utf8')),
      __isFirstParty: true
    }
  }
  const thirdParty = {}
  for (const id of ['acme.lock', 'acme.ordinary', 'acme.transient']) {
    thirdParty[id] = {
      id, kinds: ['service'], entryPoints: { service: 'Service.qml' },
      keepLoaded: id !== 'acme.transient', __isFirstParty: false,
      __sourceDir: '/fixture/plugins/' + id,
      // Third-party declarations must not grant authentication capabilities.
      omarchy: id === 'acme.lock'
        ? { clonedFrom: 'omarchy.lock' } : { capabilities: ['authentication'] },
      __hostCapabilities: ['forged']
    }
  }
  registry.stampHostCapabilities(firstParty, thirdParty)
  registry.installedPlugins = { ...firstParty, ...thirdParty }
  const disabled = new Set()
  registry.isEnabled = id => !disabled.has(id)
  registry.entryPointUrl = manifest => manifest.id
  registry.resolveEnabledId = id => id === 'omarchy.media' ? 'acme.ordinary' : id
  const created = []
  const host = {}
  const context = vm.createContext({
    console, pluginRegistry: registry, AuthServiceStore: store,
    _services: {}, serviceHost: host, omarchyPath: root,
    Component: { Ready: 1, Loading: 2, PreferSynchronous: 3 },
    Qt: {
      createComponent: id => ({
        status: 1,
        createObject(parent) {
          const instance = {
            id, parent, manifest: null, shell: null, omarchyPath: '',
            destroyCount: 0, marker: 'survives-rescan',
            destroy() { this.destroyCount++ }
          }
          created.push(instance)
          return instance
        }
      })
    },
    // Facade construction is covered separately by the native boundary suite.
    pluginShellFor: manifest => ({ pluginId: manifest.id })
  })
  context.shell = context
  loadFunctions(shellSource, [
    'publicPluginManifest', 'serviceFor', 'firstPartyServiceFor',
    'pluginOwnsTarget', 'pluginServiceFor', 'isAuthenticationService',
    'ensureService', '_syncServices', 'serviceKeepLoaded', 'unloadPluginServices'
  ], context)
  return { context, registry, store, disabled, created, host }
}

const f = fixture()
f.context._syncServices()
const initial = Object.fromEntries(f.created.map(instance => [instance.id, instance]))
for (const id of ['omarchy.lock', 'omarchy.polkit', 'acme.lock']) {
  assert(f.store.has(id) && f.context.serviceFor(id) === null && initial[id].parent === null,
    `${id} is retained privately and created without a parent`)
  assert(f.context.ensureService(id) === null && initial[id].destroyCount === 0,
    `${id} cannot be retrieved or recreated through ensureService`)
}
assert(initial['acme.ordinary'].parent === null && initial['omarchy.idle'].parent === f.host,
  'only trusted non-authentication services use the service host')
assertDeepEqual(f.registry.installedPlugins['acme.ordinary'].__hostCapabilities, [],
  'third-party capabilities cannot forge authentication classification')
assert(!('services' in f.context)
  && f.context.firstPartyServiceFor('omarchy.media') === initial['acme.ordinary']
  && f.context.pluginServiceFor('acme.ordinary', 'omarchy.media') === initial['acme.ordinary']
  && f.context.pluginServiceFor('acme.ordinary', 'omarchy.lock') === null,
  'enabled-clone and own-service lookups work without a services alias')

f.context.unloadPluginServices()
for (const [id, manifest] of Object.entries(f.registry.installedPlugins)) {
  f.registry.installedPlugins[id] = { ...manifest, name: 'Refreshed ' + id }
}
f.context._syncServices()
for (const id of ['omarchy.lock', 'omarchy.polkit', 'acme.lock', 'omarchy.idle', 'acme.ordinary']) {
  assert(initial[id].destroyCount === 0 && initial[id].marker === 'survives-rescan'
    && f.created.filter(instance => instance.id === id).length === 1
    && initial[id].manifest.name === 'Refreshed ' + id,
    `${id} keeps its original instance and receives the refreshed manifest`)
}
assert(initial['acme.transient'].destroyCount === 1
  && f.context.serviceFor('acme.transient') !== initial['acme.transient'],
  'ordinary services without keepLoaded are replaced on rescan')
assert(!('__hostCapabilities' in initial['acme.lock'].manifest)
  && !('__sourceDir' in initial['acme.lock'].manifest),
  'kept authentication clones receive detached public manifests')
initial['acme.lock'].manifest.name = 'plugin-local edit'
assert(f.registry.installedPlugins['acme.lock'].name === 'Refreshed acme.lock',
  'mutating a kept clone manifest cannot change the registry')

for (const removal of ['disable', 'remove', 'drop-kind', 'drop-entry-point']) {
  const test = fixture()
  test.context._syncServices()
  const originals = [...test.created]
  for (const id of Object.keys(test.registry.installedPlugins)) {
    if (removal === 'disable') test.disabled.add(id)
    else if (removal === 'remove') delete test.registry.installedPlugins[id]
    else if (removal === 'drop-kind') test.registry.installedPlugins[id].kinds = ['panel']
    else test.registry.installedPlugins[id].entryPoints = {}
  }
  test.context._syncServices()
  assert(originals.every(instance => instance.destroyCount === 1)
    && test.store.ids().length === 0 && Object.keys(test.context._services).length === 0,
    `${removal} removes both private authentication and public ordinary services`)
}

const promotion = fixture()
promotion.context._syncServices()
const published = promotion.context.serviceFor('acme.ordinary')
promotion.registry.installedPlugins['acme.ordinary'].__hostCapabilities = ['authentication']
promotion.context._syncServices()
assert(published.destroyCount === 1 && promotion.store.has('acme.ordinary')
  && promotion.context.serviceFor('acme.ordinary') === null,
  'a service gaining host-stamped authentication is removed from the public map')
promotion.registry.installedPlugins['acme.ordinary'].__hostCapabilities = []
promotion.registry.installedPlugins['acme.ordinary'].keepLoaded = false
promotion.context.unloadPluginServices()
promotion.context._syncServices()
assert(promotion.store.has('acme.ordinary') && promotion.context.serviceFor('acme.ordinary') === null,
  'authentication classification survives metadata mutation and instance recreation')
JS
