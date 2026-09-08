-- WirePlumber
--
-- Based on node/software-dsp.lua from WirePlumber.
-- Loads the same asahi-audio graphs, but keeps speaker DSP filter-chain
-- nodes from pausing/suspending between short-lived streams (Chromium,
-- YouTube seeks, any client that closes its PipeWire stream). That pause
-- cuts the convolver tail and pops. Mic graphs are left unchanged.
--
-- SPDX-License-Identifier: MIT

log = Log.open_topic("s-node")

config = {}
config.rules = Conf.get_section_as_json("node.software-dsp.rules", Json.Array{})

clients_om = ObjectManager {
  Interest { type = "client" }
}

filter_nodes = {}
hidden_nodes = {}

-- Speaker graphs (graph.json, graph-j414.json, ...) not mic graphs.
local function is_speaker_graph(path)
  return type(path) == "string" and path:find("/graph", 1, true) ~= nil
end

-- Keep the FIR/convolver chain processing silence instead of pausing when
-- the client stream disappears. Matches AsahiLinux/asahi-audio#84.
local function keep_speaker_dsp_alive(args)
  args = args:gsub('"node%.passive"%s*:%s*"true"', '"node.passive": false')
  if args:find("session.suspend-timeout-seconds", 1, true) then
    return args
  end
  args = args:gsub(
    '"capture%.props"%s*:%s*{',
    '"capture.props": { "node.pause-on-idle": false, "session.suspend-timeout-seconds": 0,'
  )
  args = args:gsub(
    '"playback%.props"%s*:%s*{',
    '"playback.props": { "node.pause-on-idle": false, "session.suspend-timeout-seconds": 0,'
  )
  return args
end

SimpleEventHook {
  name = "node/dsp/create-dsp-node",
  interests = {
    EventInterest {
      Constraint  { "event.type", "=", "node-added" },
    },
  },
  execute = function(event)
    local node = event:get_subject()
    JsonUtils.match_rules (config.rules, node.properties, function (action, value)
      if action == "create-filter" then
        local props = value:parse (1)
        log:debug("DSP rule found for " .. node.properties["node.name"])

        if props["filter-graph"] then
          log:debug("Loading filter graph for " .. node.properties["node.name"])
          local graph = props["filter-graph"]
          if type(graph) == "string" and is_speaker_graph(tostring(graph)) then
            graph = keep_speaker_dsp_alive(graph)
          end
          filter_nodes[node.id] = LocalModule("libpipewire-module-filter-chain", graph, {})
        elseif props["filter-path"] then
          log:debug("Loading filter graph for " .. node.properties["node.name"] .. " from disk")
          local conf = Conf(props["filter-path"], {
            ["as-section"] = "node.software-dsp.graph",
            ["no-fragments"] = true
          })
          local err = conf:open()
          if not err then
            local args = conf:get_section_as_json("node.software-dsp.graph"):to_string()
            if is_speaker_graph(props["filter-path"]) then
              args = keep_speaker_dsp_alive(args)
              log:info("Keeping speaker DSP alive for " .. props["filter-path"])
            end
            filter_nodes[node.id] = LocalModule("libpipewire-module-filter-chain", args, {})
          else
            log:warning("Unable to load filter graph for " .. node.properties["node.name"])
          end
        end

        if props["hide-parent"] then
          log:debug("Setting permissions to '-' on " .. node.properties["node.name"] .. " for open clients")
          for client in clients_om:iterate{ type = "client" } do
            if not client["properties"]["wireplumber.daemon"] then
              client:update_permissions{ [node["bound-id"]] = "-" }
            end
          end
          hidden_nodes[node["bound-id"]] = node.id
        end
      end
    end)
  end
}:register()

SimpleEventHook {
  name = "node/dsp/free-dsp-node",
  interests = {
    EventInterest {
      Constraint  { "event.type", "=", "node-removed" },
    },
  },
  execute = function(event)
    local node = event:get_subject()
    if filter_nodes[node.id] then
      log:debug("Freeing filter on node " .. node.id)
      filter_nodes[node.id] = nil
      hidden_nodes[node["bound-id"]] = nil
    end
  end
}:register()

clients_om:connect("object-added", function (om, client)
  for id, _ in pairs(hidden_nodes) do
    if not client["properties"]["wireplumber.daemon"] then
      client:update_permissions { [id] = "-" }
    end
  end
end)

clients_om:activate()
