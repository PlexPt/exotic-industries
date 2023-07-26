local model = {}

--====================================================================================================
--GATE
--====================================================================================================

-- teleport costs in MJ
-- 100MW spare per portal -> 50 Items/s
model.energy_costs = {
    ["player"] = 100,
    ["item"] = 2
}

model.inverse_surface = {
    ["gaia"] = "nauvis",
    ["nauvis"] = "gaia"
}

--DOC
------------------------------------------------------------------------------------------------------

-- placing the gate will place hidden container ontop
-- gui allows selection of exit location
-- item transport is only possible, if exit location is coupled to exit point
-- item transport consumes energy
-- gui allows to set condition for item transport trigger

--UTIL
-----------------------------------------------------------------------------------------------------

function model.entity_check(entity)

    if entity == nil then
        return false
    end

    if not entity.valid then
        return false
    end

    return true
end


function model.check_global_init()

    if not global.ei.gate then
        global.ei.gate = {}
    end

    if not global.ei.gate.gate then
        global.ei.gate.gate = {}
    end

    if not global.ei.gate.exit_platform then
        global.ei.gate.exit_platform = {}
    end

end


function model.get_transfer_inv(transfer)
    -- transfer is either a player index, a robot, or nil
    -- needed to prevent unregistration when the transferer cant mine due to full inv

    if not transfer then
        return nil
    end

    if type(transfer) == "number" then
        -- player index
        local player = game.get_player(transfer)
        return player.get_main_inventory()
    end

    if transfer.valid then
        -- robot
        local robot = transfer
        return robot.get_inventory(defines.inventory.robot_cargo)
    end

    return nil

end


function model.transfer_valid(transfer)

    local target_inv = model.get_transfer_inv(transfer)
    
    if not target_inv then
        -- case for when destroyed by gun f.e. -> need to unregister
        return true
    end

    -- check if target has space for gate item
    if target_inv.can_insert({name = "ei_gate", count = 1}) then
        target_inv.insert({name = "ei_gate", count = 1})
        return true
    end

    return false

end


function model.transfer(transfer)

    local target_inv = model.get_transfer_inv(transfer)
    
    if not target_inv then
        return
    end

    target_inv.insert({name = "ei_gate", count = 1})
end


function model.register_gate(gate, container)

    model.check_global_init()
    
    local gate_unit = gate.unit_number

    if global.ei.gate.gate[gate_unit] then
        return
    end

    global.ei.gate.gate[gate_unit] = {}
    global.ei.gate.gate[gate_unit].gate = gate
    global.ei.gate.gate[gate_unit].container = container

    -- set endpoint to (0, 0)
    global.ei.gate.gate[gate_unit].exit = {surface = model.inverse_surface[gate.surface.name], x = 0, y = 0}
    global.ei.gate.gate[gate_unit].state = false


end


function model.find_gate(container)

    if not container then
        return nil
    end

    if container.name ~= "ei_gate-container" then
        return nil
    end

    local gate = container.surface.find_entity("ei_gate", container.position)

    if not gate then
        return nil
    end

    return gate

end

--GATE LOGIC
-----------------------------------------------------------------------------------------------------

function model.make_gate(gate)

    -- create and register cate-container
    local gate_container = gate.surface.create_entity({
        name = "ei_gate-container",
        position = gate.position,
        force = gate.force
    })

    model.register_gate(gate, container)

end


function model.destroy_gate(gate, container)

    if not gate then
        -- look for gate at container position
        gate = container.surface.find_entity("ei_gate", container.position)
    end

    if not container then
        -- look for container at gate position
        container = gate.surface.find_entity("ei_gate-container", gate.position)
    end

    if not gate or not container then
        return
    end

    local gate_unit = gate.unit_number

    if model.entity_check(gate) then
        gate.destroy()
    end

    if model.entity_check(container) then
        container.destroy()
    end

    if global.ei.gate.gate[gate_unit] then
        global.ei.gate.gate[gate_unit] = nil
    end

end


function model.check_for_teleport()

    -- loop over all gates and check if there is a player in range
    -- if so check if enough power and if endpoint has exit
    -- spawn in exit if not and teleport

    if not global.ei.gate then
        return
    end

    if not global.ei.gate.gate then
        return
    end

    for i,v in pairs(global.ei.gate.gate) do

        local gate = global.ei.gate.gate[i].gate

        if not model.gate_state(gate) then
            goto continue
        end

        -- TODO: change this to only inner gate for flying drones
        local players = gate.surface.find_entities_filtered({
            area = {
                {gate.position.x - 7, gate.position.y - 7},
                {gate.position.x + 7, gate.position.y + 7}
            },
            type = "character"
        })

        if #players == 0 then
            goto continue
        end

        if not model.pay_energy(gate, {"player"}) then
            goto continue
        end

        model.render_exit(gate)

        model.teleport_player(players[1], gate)

        ::continue::

    end

end


function model.gate_state(gate)

    -- will be false if no exit is set

    if not global.ei.gate.gate[gate.unit_number].exit then
        return false
    end

    if not global.ei.gate.gate[gate.unit_number].state then
        return false
    end

    return true
end


function model.pay_energy(gate, tablein)

    -- check if gate has enough energy to transport all contents of tablein
    -- if so, pay and return true

    local energy = 0
    for i,v in ipairs(tablein) do
        if type(v) == "string" and v == "player" then
            energy = energy + model.energy_costs.player
        end

        if type(v) == "table" then --for item
            energy = energy + model.energy_costs.item * v.count
        end
    end

    -- change to Mj
    energy = energy * 1000000

    if gate.energy < energy then
        return false
    end

    gate.energy = gate.energy - energy
    return true

end


function model.teleport_player(character, gate)

    local player = character.player
    if not player then
        return
    end

    local exit = global.ei.gate.gate[gate.unit_number].exit

    -- teleport player
    player.teleport({exit.x, exit.y}, exit.surface)

end

--RENDERING
-----------------------------------------------------------------------------------------------------

function model.render_exit(gate)

    local gate_unit = gate.unit_number
    local exit = global.ei.gate.gate[gate_unit].exit
    local animation

    -- check if exit already exists, if at same pos and surface extend time to live
    if global.ei.gate.gate[gate_unit].exit_animation then

        animation = global.ei.gate.gate[gate_unit].exit_animation

        -- check if still valid, might be very old
        if rendering.is_valid(animation) then

            -- also test pos and surface
            local target = rendering.get_target(animation)
            local surface = rendering.get_surface(animation)
            
            if target.x == exit.x and target.y == exit.y and surface == exit.surface then
                
                -- extend time to live
                rendering.set_time_to_live(animation, 180)
                return
            end
        end
    end

    -- create new exit
    animation = rendering.draw_animation{
        animation = "ei_exit-simple",
        target = {exit.x, exit.y},
        surface = exit.surface,
        render_layer = "object",
        animation_speed = 0.6,
        x_scale = 1,
        y_scale = 1,
        time_to_live = 180,
    }

    global.ei.gate.gate[gate_unit].exit_animation = animation
    
end


function model.render_animation(gate)

    local gate_unit = gate.unit_number

    if global.ei.gate.gate[gate_unit].animation then return end

    animation = rendering.draw_animation{
        animation = "ei_gate-runnig",
        target = gate,
        surface = gate.surface,
        render_layer = "object",
        x_scale = 1,
        y_scale = 1
    }

    global.ei.gate.gate[gate_unit].animation = animation

end


function model.update_renders()

    if not global.ei.gate then
        return
    end

    if not global.ei.gate.gate then
        return
    end

    for i,v in pairs(global.ei.gate.gate) do

        local gate = global.ei.gate.gate[i].gate
        local state = model.gate_state(gate)
        -- if state true -> check if need to render animation
        -- if state false -> check if need to destroy animation + cleanup

        if not state then
            if global.ei.gate.gate[i].animation then
                rendering.destroy(global.ei.gate.gate[i].animation)
                global.ei.gate.gate[i].animation = nil
            end
        else
            model.render_animation(gate)
        end

    end

end


--GUI
-----------------------------------------------------------------------------------------------------

function model.open_gui(player)

    if player.gui.relative["ei_gate-console"] then
        model.close_gui(player)
    end

    local root = player.gui.relative.add{
        type = "frame",
        name = "ei_gate-console",
        anchor = {
            gui = defines.relative_gui_type.container_gui,
            name = "ei_gate-container",
            position = defines.relative_gui_position.right,
        },
        direction = "vertical",
    }

    do -- Titlebar
        local titlebar = root.add{type = "flow", direction = "horizontal"}
        titlebar.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-title"},
            style = "frame_title",
        }

        titlebar.add{
            type = "empty-widget",
            style = "ei_titlebar_nondraggable_spacer",
            ignored_by_interaction = true
        }

        titlebar.add{
            type = "sprite-button",
            sprite = "virtual-signal/informatron",
            tooltip = {"exotic-industries.gui-open-informatron"},
            style = "frame_action_button",
            tags = {
                parent_gui = "ei_gate-console",
                action = "goto-informatron",
                page = "gate"
            }
        }
    end

    local main_container = root.add{
        type = "frame",
        name = "main-container",
        direction = "vertical",
        style = "inside_shallow_frame",
    }

    do -- Status subheader
        main_container.add{
            type = "frame",
            style = "ei_subheader_frame",
        }.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-status-title"},
            style = "subheader_caption_label",
        }
    
        local status_flow = main_container.add{
            type = "flow",
            name = "status-flow",
            direction = "vertical",
            style = "ei_inner_content_flow",
        }

        status_flow.add{
            type = "progressbar",
            name = "energy",
            caption = {"exotic-industries.gate-gui-status-energy", 0},
            tooltip = {"exotic-industries.gate-gui-status-energy-tooltip"},
            style = "ei_status_progressbar"
        }

    end


    do -- Control subheader
        main_container.add{
            type = "frame",
            style = "ei_subheader_frame",
        }.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-control-title"},
            style = "subheader_caption_label",
        }
    
        local control_flow = main_container.add{
            type = "flow",
            name = "control-flow",
            direction = "horizontal",
            style = "ei_inner_content_flow_horizontal",
        }

        local target_flow = control_flow.add{
            type = "flow",
            name = "target-flow",
            direction = "vertical"
        }

        -- Surface
        local dropdown_flow = target_flow.add{
            type = "flow",
            name = "dropdown-flow",
            direction = "vertical"
        }
    
        dropdown_flow.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-control-dropdown-label"},
            tooltip = {"exotic-industries.gate-gui-control-dropdown-label-tooltip"}
        }
        dropdown_flow.add{
            type = "drop-down",
            name = "surface",
            tags = {
                parent_gui = "ei_gate-console",
                action = "set-surface"
            }
        }

        -- Position
        local position_flow = target_flow.add{
            type = "flow",
            name = "position-flow",
            direction = "vertical"
        }

        position_flow.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-control-position-label"},
            tooltip = {"exotic-industries.gate-gui-control-position-label-tooltip"}
        }
        position_flow.add{
            type = "button",
            name = "position-button",
            caption = {"exotic-industries.gate-gui-control-position-button", 0, 0},
            tags = {
                action = "set-position",
                parent_gui = "ei_gate-console",
            }
        }

        position_flow.add{
            type = "label",
            caption = {"exotic-industries.gate-gui-control-state-label"},
        }
        position_flow.add{
            type = "button",
            name = "state-button",
            caption = {"exotic-industries.gate-gui-control-state-button", "OFF"},
            style = "ei_button",
            tags = {
                action = "set-state",
                parent_gui = "ei_gate-console",
            }
        }

        -- Target cam
        local camera_frame = control_flow.add{
            type = "frame",
            name = "camera-frame",
            style = "ei_small_camera_frame"
        }
        camera_frame.add{
            type = "camera",
            name = "target-camera",
            position = {0, 0},
            surface_index = 1,
            zoom = 0.25,
            style = "ei_small_camera"
        }

    end

    local data = model.get_data(model.find_gate(player.opened))
    model.update_gui(player, data)

end


function model.update_gui(player, data, ontick)

    if not data then return end

    local root = player.gui.relative["ei_gate-console"]
    local status = root["main-container"]["status-flow"]
    local control = root["main-container"]["control-flow"]


    local energy = status["energy"]
    local dropdown = control["target-flow"]["dropdown-flow"]["surface"]
    local position = control["target-flow"]["position-flow"]["position-button"]
    local camera = control["camera-frame"]["target-camera"]
    local state = control["target-flow"]["position-flow"]["state-button"]

    -- Update status
    energy.caption = {"exotic-industries.gate-gui-status-energy", string.format("%.0f", data.energy/1000000)}
    energy.value = data.energy / data.max_energy

    -- if ontick update dont redo user input stuff
    if ontick then return end

    -- Surface dropdown
    local selected_index
    local surface_strings = {}
    for i, possible_surface in pairs(data.surfaces) do
        surface_strings[i] = possible_surface
        if data.target_surface == possible_surface then
            selected_index = i
        end
    end
    dropdown.items = surface_strings
    if selected_index then
        dropdown.selected_index = selected_index
    end
    dropdown.tags = {
        parent_gui = "ei_gate-console",
        action = "set-surface",
        surface_list = data.surfaces -- to get surface later on with index
    }

    -- Position button
    position.caption = {"exotic-industries.gate-gui-control-position-button", data.target_pos.x, data.target_pos.y}

    -- Camera
    camera.position = {data.target_pos.x, data.target_pos.y}
    camera.surface_index = game.get_surface(data.target_surface).index or 1

    -- State button
    if data.state then
        state.style = "ei_green_button"
        state.caption = {"exotic-industries.gate-gui-control-state-button", "ON"}
    else
        state.style = "ei_button"
        state.caption = {"exotic-industries.gate-gui-control-state-button", "OFF"}
    end

end


function model.update_player_guis()

    for _, player in pairs(game.players) do
        if player.gui.relative["ei_gate-console"] then
            if not player.opened then
                model.close_gui(player)
                return
            end

            local gate = model.find_gate(player.opened)
            local data = model.get_data(gate)
            model.update_gui(player, data, true)
        end
    end

end


function model.update_surface(player)

    local entity = player.opened
    local root = player.gui.relative["ei_gate-console"]
    if not root or not entity then return end

    if entity.name ~= "ei_gate-container" then return end

    local dropdown = root["main-container"]["control-flow"]["target-flow"]["dropdown-flow"]["surface"]
    local selected_surface = dropdown.tags.surface_list[dropdown.selected_index]

    local gate = model.find_gate(entity)

    if not gate then return end

    global.ei.gate.gate[gate.unit_number].exit.surface = selected_surface

    local data = model.get_data(gate)
    model.update_gui(player, data)

end


function model.get_data(gate)

    if not gate then return end

    local data = {}

    data.max_energy = gate.electric_buffer_size
    data.energy = gate.energy

    -- get list of all surfaces
    local surfaces = {}
    for i,v in pairs(game.surfaces) do
        table.insert(surfaces, v.name)
    end
    data.surfaces = surfaces

    local exit = global.ei.gate.gate[gate.unit_number].exit
    data.target_surface = exit.surface
    data.target_pos = {x = exit.x, y = exit.y}
    data.state = global.ei.gate.gate[gate.unit_number].state

    return data

end

--HANDLERS
-----------------------------------------------------------------------------------------------------

function model.on_built_entity(entity)

    if model.entity_check(entity) == false then
        return
    end

    if entity.name == "ei_gate" then

        model.make_gate(entity)
        ei_gaia.create_gaia()
    end

end


function model.on_destroyed_entity(entity, transfer)

    if model.entity_check(entity) == false then
        return
    end

    if entity.name ~= "ei_gate" and entity.name ~= "ei_gate-container" then
        return
    end

    if not model.transfer_valid(transfer) then
        return
    end

    if entity.name == "ei_gate" then

        model.destroy_gate(entity, nil)
        return

    end

    -- normaly gate gets mined/destroyed first
    if entity.name == "ei_gate-container" then

        model.destroy_gate(nil, entity)
        return

    end

end


function model.on_gui_click(event)
    --[[
    if event.element.tags.action == "control-start" then
        model.change_stage(game.get_player(event.player_index))
    end
    ]]

    if event.element.tags.action == "goto-informatron" then
        --[[ 
        if game.forces["player"].technologies["ei_gate"].enabled == true then
            remote.call("informatron", "informatron_open_to_page", {
                player_index = event.player_index,
                interface = "exotic-industries-informatron",
                page_name = event.element.tags.page
            })
        end
        ]]
    end
end


function model.on_gui_selection_state_changed(event)
    local action = event.element.tags.action

    if action == "set-surface" then
        model.update_surface(game.get_player(event.player_index))
    end
end


function model.close_gui(player)
    if player.gui.relative["ei_gate-console"] then
        player.gui.relative["ei_gate-console"].destroy()
    end
end


function model.on_gui_opened(event)
    model.open_gui(game.get_player(event.player_index))
end


function model.update()

    model.check_for_teleport()

    model.update_player_guis()

    model.update_renders()

end

--GUI HANDLER
-----------------------------------------------------------------------------------------------------

return model