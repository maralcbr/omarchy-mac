#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Run the production facade factories and proxy methods with QObject/binding
# test doubles. Native QML reactivity and graphical clicks need a compositor.
run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const read = file => fs.readFileSync(path.join(root, file), 'utf8')
const shellSource = read('shell/shell.qml')
const barSource = read('shell/plugins/bar/Bar.qml')
const apiSource = read('shell/services/PluginShellApi.qml')
const proxySource = read('shell/services/PluginFirstPartyServiceApi.qml')
const builtin = JSON.parse(read('shell/plugins/bar/widgets/Indicators.manifest.json'))

function loadFunctions(source, names, context) {
  for (const name of names) {
    const match = source.match(new RegExp(`^  function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?^  \\}`, 'm'))
    if (!match) fail(`production function is present: ${name}`)
    vm.runInContext(match[0], context)
  }
}

function component(source, methods, defaults = {}) {
  return {
    createObject(parent, properties) {
      const target = vm.createContext({
        ...defaults, ...properties, parent, destroyed: false,
        destroy() { this.destroyed = true }
      })
      loadFunctions(source, methods, target)
      return new Proxy(target, {
        set(object, key, value) {
          if (value && value.binding)
            Object.defineProperty(object, key, { configurable: true, get: value.binding })
          else object[key] = value
          return true
        }
      })
    }
  }
}

const id = 'local.indicators'
const manifest = { ...builtin, id, omarchy: { clonedFrom: builtin.id } }
const enabled = new Set([id])
const configured = new Set([id])
const implementations = {}
const services = {
  'omarchy.idle': { stayAwake: true, setIdleEnabled(value) { this.stayAwake = !value } },
  'omarchy.nightlight': { enabled: true, setNightlight(value) { this.enabled = value } },
  'omarchy.notifications': { doNotDisturb: true, setDoNotDisturb(value) { this.doNotDisturb = value } }
}
const context = vm.createContext({
  Util: { isPlainObject: value => !!value && typeof value === 'object' && !Array.isArray(value) },
  Qt: { binding: binding => ({ binding }) },
  _services: services,
  _pluginShellApis: {}, _pluginShellApiDescriptors: {}, _pluginBarEntryShellApis: {},
  _pluginAppLibraryApis: {}, _pluginFirstPartyServiceApis: {},
  _pluginRegistryApis: {}, _pluginBarWidgetRegistryApis: {}, _pluginBarStateApis: {},
  activeBarManifest: { id: 'omarchy.bar', __isFirstParty: true },
  pluginRegistry: {
    installedPlugins: { [id]: manifest },
    isEnabled: key => enabled.has(key),
    resolveEnabledId: key => implementations[key] || key,
    findEntryLocation: (config, key) => ({ kind: configured.has(key) ? 'bar' : 'plugin' })
  },
  shellConfig: {}, barConfig: {},
  pluginBarStateFor: () => null,
  pluginShellApiComponent: component(apiSource,
    ['serviceFor', 'firstPartyServiceFor', 'pluginShellForBarEntry', 'mutateShellConfig'],
    { _serviceLookup: null, _firstPartyServiceLookup: null, _barEntryShellLookup: null }),
  pluginFirstPartyServiceApiComponent: component(proxySource,
    ['setIdleEnabled', 'setNightlight', 'setDoNotDisturb'])
})
context.shell = context
// Load definitions, not the QML root: imports track production helper changes
// and the same behavioral test can run against the pre-fix shell.
loadFunctions(shellSource,
  [...shellSource.matchAll(/^  function (\w+)\(/gm)].map(match => match[1]), context)
context.pluginBarStateFor = () => null

// Use the actual trusted-bar injection function, including its cached bar API.
const bar = vm.createContext({ shell: context, pluginBarApis: { slot: {} } })
bar.root = bar
loadFunctions(barSource, ['pluginBarApiFor'], bar)
const api = bar.pluginBarApiFor('slot', id, true).shell
const serviceIds = ['omarchy.idle', 'omarchy.nightlight', 'omarchy.notifications']
const proxies = serviceIds.map(key => api.firstPartyServiceFor(key))
assert(proxies.every(Boolean), 'Indicators clone under the trusted bar receives all three service proxies')
assertDeepEqual(Object.keys(context._pluginFirstPartyServiceApis), serviceIds.map(key => `${id}::${key}`),
  'Indicators proxies are eagerly created without the media proxy')
for (let i = 0; i < serviceIds.length; i++) {
  const key = serviceIds[i]
  assert(proxies[i] !== services[key] && proxies[i].parent === null && api.serviceFor(key) === null,
    `${key} exposes a detached proxy, never the live service`)
}
assert(proxies[0].stayAwake && proxies[1].enabled && proxies[2].doNotDisturb,
  'Indicators proxies mirror their service scalar state')
proxies[0].setIdleEnabled(true)
proxies[1].setNightlight(false)
proxies[2].setDoNotDisturb(false)
assert(!services['omarchy.idle'].stayAwake && !services['omarchy.nightlight'].enabled
  && !services['omarchy.notifications'].doNotDisturb,
  'Indicators proxy callbacks update exactly their non-authentication service')
const idleClone = { stayAwake: false, setIdleEnabled(value) { this.stayAwake = !value } }
services['local.idle'] = idleClone
implementations['omarchy.idle'] = 'local.idle'
proxies[0].setIdleEnabled(false)
assert(idleClone.stayAwake && proxies[0].stayAwake && !services['omarchy.idle'].stayAwake,
  'an existing proxy follows the enabled service clone')

for (const key of ['omarchy.lock', 'omarchy.polkit', 'omarchy.media', 'local.idle', 'unrelated.service']) {
  assert(api.firstPartyServiceFor(key) === null && api.serviceFor(key) === null,
    `Indicators facade denies unrelated service lookup: ${key}`)
}
assert(api.pluginShellForBarEntry('other', id) === null && !api.mutateShellConfig(() => {}),
  'Indicators compatibility does not confer full-bar factories or configuration mutation')

context.activeBarManifest = { id: 'local.bar', kinds: ['bar'] }
assert(serviceIds.every(key => api.firstPartyServiceFor(key) === null),
  'Indicators service lookups are denied while a replacement bar is active')
const entryApi = context.pluginShellForBarEntry('local.bar:slot', id)
assert(serviceIds.every(key => entryApi.firstPartyServiceFor(key) === null),
  'replacement-bar entry facade remains service-less')
context.activeBarManifest = null
assert(serviceIds.every(key => api.firstPartyServiceFor(key) === null),
  'Indicators service lookups are denied without a trusted active bar')
context.activeBarManifest = { id: 'omarchy.bar', __isFirstParty: true }
configured.delete(id)
assert(serviceIds.every(key => api.firstPartyServiceFor(key) === null),
  'unconfigured Indicators clones cannot look up the services')
configured.add(id)
enabled.delete(id)
assert(serviceIds.every(key => api.firstPartyServiceFor(key) === null),
  'disabled Indicators clones cannot look up the services')
enabled.add(id)
assert(serviceIds.every(key => api.firstPartyServiceFor(key) !== null),
  'restoring the configured enabled clone restores narrow lookups')

for (const changed of [
  { ...manifest, omarchy: { clonedFrom: 'omarchy.clock' } },
  { ...manifest, kinds: ['panel'] }
]) {
  context.pluginRegistry.installedPlugins[id] = changed
  assert(serviceIds.every(key => api.firstPartyServiceFor(key) === null),
    'lookups recheck the current clone source and widget kind')
}
context.prunePluginApis()
assert(api.destroyed && proxies.every(proxy => proxy.destroyed)
  && !context._pluginShellApis[id] && Object.keys(context._pluginFirstPartyServiceApis).length === 0,
  'a changed Indicators capability revokes the facade and its proxy cache')
const ordinary = context.pluginShellFor(context.pluginRegistry.installedPlugins[id])
assert(serviceIds.every(key => ordinary.firstPartyServiceFor(key) === null),
  'ordinary plugins do not receive Indicators compatibility')
context.pluginRegistry.installedPlugins[id] = manifest
const restored = context.pluginShellFor(manifest)
assert(restored !== ordinary && ordinary.destroyed
  && serviceIds.every(key => restored.firstPartyServiceFor(key) !== null),
  'adding back the Indicators capability recreates the facade and eager proxies')
const hosted = context.createScopedPluginShell(manifest, 'hosted:' + id, false, false)
assert(serviceIds.every(key => hosted.firstPartyServiceFor(key) === null),
  'service-less hosted facades cannot acquire Indicators compatibility')

const fullBar = { id: 'local.bar', kinds: ['bar'] }
context.pluginRegistry.installedPlugins[fullBar.id] = fullBar
const fullBarApi = context.pluginShellFor(fullBar)
assert(fullBarApi.firstPartyServiceFor('omarchy.media') !== null
  && fullBarApi.firstPartyServiceFor('omarchy.lock') === null
  && fullBarApi.firstPartyServiceFor('omarchy.polkit') === null,
  'existing full-bar non-authentication proxy scope is unchanged')
JS
