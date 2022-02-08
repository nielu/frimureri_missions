--[[
	location tags:
	small - 5x5 or 7x7 meters max
	medium - 20x20 meters max (small vehicles can spawn there too)
	large - 50x50 meters max (small and medium vehicles can spawn there too)
	underwater - spawn under the water (for ROVs, submarines, sunken vessels and air crashes)
	sea - spawn on the water in the sea (for any vessels or air crashes)
	river - spawn on the water on the river (for river themed boats only)
	shore - spawn on the shoreline (for vessels crashed into the land)
	offshore - spawn in the ocean tile (for vehicles to spawn away from any land tile)
	land - spawn on the land (for land vehicles or air crashes)
	road - spawn on the road (for land vehicles: cars, vans, buses, trucks)
	offroad - spawn off the road (for rolled over land vehicles)
	rocks - spawn at shallow rocks if have sea tag and mountains if have land tag
	forest - spawn somewhere in the deep of the woods (air crash or lost survivor for example)
	camp - spawn for camping themed vehicles (vans, RVs, tents)
	port - spawn for cargo vehicles (forklifts, loaders, trucks, semitrailers, fallen cranes)
	quarry - spawn for industry vehicles (bulldozers, excavators, dump trucks)
	alba - geo tag for main biome
	sawyer - geo tag for mainlaind biome
	arctic - geo tag for arctic biome (for Arctic themed vehicles only for example)

	capabilities:
	tow - for vehicles that can be towed to a destination
	repair - for vehicle sthat can be repaired
--]] g_savedata = {
    spawn_counter = 60 * 30,
    id_counter = 0,
    missions = {},
    mission_frequency = 25 * 60 * 60,
    mission_life_base = 45 * 60 * 60,
    disasters = {}
}
g_zones = {}
g_zones_hospital = {}
g_output_log = {}
g_objective_update_counter = 0
g_min_limit_travel_distance = 150
g_max_limit_travel_distance = 3000
g_damage_tracker = {}

g_fragile_cargo_health = 50
g_sources = {}
g_clear_areas = {}
g_spawns = {}
g_players = {}

g_objective_types = {
    locate_zone = {
        update = function(self, mission, objective, delta_worldtime)
            -- test if any player is within 100m of the zone

            local players = server.getPlayers()

            for player_index, player_object in pairs(players) do
                local distance_to_zone = matrix.distance(server.getPlayerPos(player_object.id), objective.transform)

                if distance_to_zone < 150 then
                    g_mission_types[mission.type]:on_locate(mission, objective.transform)
                    return true
                end
            end

            return false
        end
    },
    locate_vehicle = {
        update = function(self, mission, objective, delta_worldtime)
            -- test if any player is within 100m of the zone

            local players = server.getPlayers()

            for player_index, player_object in pairs(players) do
                local playerPos = server.getPlayerPos(player_object.id)
                local vehiclePos = server.getVehiclePos(objective.vehicle_id)
                local distance_to_zone = matrix.distance(playerPos, vehiclePos)

                if distance_to_zone < 200 then
                    g_mission_types[mission.type]:on_locate(mission, vehiclePos)
                    return true
                end
            end

            return false
        end
    },
    rescue_casualty = {
        update = function(self, mission, objective, delta_worldtime)
            -- there is only one survivor per objective but iterate table to follow objective pattern
            for k, obj in pairs(objective.objects) do
                local c = server.getCharacterData(obj.id)
                if c then
                    if c.dead then
                        server.notify(-1, "Casualty Died", "A casualty is believed to have died.", 3)
                        mission.data.survivor_dead_count = mission.data.survivor_dead_count + 1
                        return true
                    else
                        local is_in_zone = isPosInZones(server.getObjectPos(obj.id), g_zones_hospital)

                        if obj.is_bleed and c.hp > 0 then
                            obj.bleed_counter = obj.bleed_counter + 30

                            if obj.bleed_counter > 600 then
                                obj.bleed_counter = 0
                                c.hp = c.hp - 1
                                server.setCharacterData(obj.id, c.hp, true, false)
                            end
                        end

                        if is_in_zone then
                            if g_savedata.rescued_characters[obj.id] == nil then
                                g_savedata.rescued_characters[obj.id] = 1
                            end

                            local reward = math.floor(objective.reward_value * (0.5 + (c.hp / 200)))
                            server.notify(-1, "Casualty Rescued",
                                "A casualty has been successfully rescued to the hospital. Rewarded $" .. reward .. ".",
                                4)
                            server.setCurrency(server.getCurrency() + reward, server.getResearchPoints() + 1)
                            return true
                        end
                    end
                end
            end

            return false
        end
    },
    extinguish_fire = {
        update = function(self, mission, objective, delta_worldtime)
            local is_complete = true

            for k, fire in pairs(objective.objects) do
                local is_fire_on = server.getFireData(fire.id)

                if is_fire_on then
                    is_complete = false
                end
            end

            if mission.data.vehicles ~= nil then
                for _, vehicle_object in pairs(mission.data.vehicles) do
                    if server.getVehicleFireCount(vehicle_object.id) > 0 then
                        is_complete = false
                    end
                end
            end

            if is_complete then
                server.notify(-1, "Fire Extinguished",
                    "Fire has been extinguished. Rewarded $" .. objective.reward_value .. ".", 4)
                server.setCurrency(server.getCurrency() + objective.reward_value, server.getResearchPoints() + 1)
            end

            return is_complete
        end
    },
    repair_vehicle = {
        update = function(self, mission, objective, delta_worldtime)
            local is_complete = false

            if g_damage_tracker[objective.vehicle_id] ~= nil then
                if g_damage_tracker[objective.vehicle_id] < 1 then
                    is_complete = true
                end
            elseif objective.damaged == false and server.getVehicleSimulating(objective.vehicle_id) then
                objective.damaged = true
                local data, success = server.getVehicleSign(objective.vehicle_id, "Faulty Panel")
                if success == false then
                    server.announce("error", "no sign")
                    return true
                end
                g_damage_tracker[objective.vehicle_id] = 0
                server.addDamage(objective.vehicle_id, 100, data.pos.x, data.pos.y, data.pos.z)
            end

            if is_complete then
                g_damage_tracker[objective.vehicle_id] = nil
                server.notify(-1, "Repair complete",
                    "Full repair has been completed. Rewarded $" .. objective.reward_value .. ".", 4)
                server.setCurrency(server.getCurrency() + objective.reward_value, server.getResearchPoints() + 1)
            end

            return is_complete
        end
    },
    transport_character = {
        update = function(self, mission, objective, delta_worldtime)
            -- there is only one survivor per objective but iterate table to follow objective pattern
            for k, obj in pairs(objective.objects) do
                local c = server.getCharacterData(obj.id)
                local is_in_zone = server.isInTransformArea(server.getObjectPos(obj.id),
                    objective.destination.transform, objective.destination.size.x, objective.destination.size.y,
                    objective.destination.size.z)

                if c then
                    if c.dead then
                        mission.data.survivor_dead_count = mission.data.survivor_dead_count + 1
                    end

                    if is_in_zone and (c.incapacitated == false) and (c.dead == false) then
                        if g_savedata.rescued_characters[obj.id] == nil then
                            g_savedata.rescued_characters[obj.id] = 1
                        end

                        local reward = math.floor(objective.reward_value * (0.2 + (c.hp / 125)))
                        server.notify(-1, "Delivery Complete",
                            "The passenger has reached their destination. Rewarded $" .. reward .. ".", 4)
                        server.setCurrency(server.getCurrency() + reward, server.getResearchPoints() + 1)
                        return true
                    end
                end
            end
            return false
        end
    },
    transport_vehicle = {
        update = function(self, mission, objective, delta_worldtime)
            local object_count = 0
            local object_delivered_count = 0

            for k, obj in pairs(objective.objects) do
                object_count = object_count + 1
                local is_in_zone = server.isInTransformArea(server.getVehiclePos(obj.id),
                    objective.destination.transform, objective.destination.size.x, objective.destination.size.y,
                    objective.destination.size.z)

                if is_in_zone then
                    object_delivered_count = object_delivered_count + 1
                end
            end

            if object_delivered_count == object_count then
                if objective.reward_value == nil then
                    objective.reward_value = 3800
                end
                server.notify(-1, "Delivery Complete",
                    "The consignment has been delivered. Rewarded $" .. objective.reward_value .. ".", 4)
                server.setCurrency(server.getCurrency() + objective.reward_value, server.getResearchPoints() + 1)
                return true
            else
                return false
            end
        end
    },
    transport_object = {
        update = function(self, mission, objective, delta_worldtime)
            local object_count = 0
            local object_delivered_count = 0

            for k, obj in pairs(objective.objects) do
                object_count = object_count + 1
                local is_in_zone = server.isInTransformArea(server.getObjectPos(obj.id),
                    objective.destination.transform, objective.destination.size.x, objective.destination.size.y,
                    objective.destination.size.z)

                if is_in_zone then
                    object_delivered_count = object_delivered_count + 1
                end
            end

            if object_delivered_count == object_count then
                if objective.reward_value == nil then
                    objective.reward_value = 6400
                end
                server.notify(-1, "Delivery Complete",
                    "The consignment has been delivered. Rewarded $" .. objective.reward_value .. ".", 4)
                server.setCurrency(server.getCurrency() + objective.reward_value, server.getResearchPoints() + 1)
                return true
            else
                return false
            end
        end
    },
    move_to_zones = {
        update = function(self, mission, objective, delta_worldtime)
            -- there is only one survivor per objective but iterate table to follow objective pattern
            for k, obj in pairs(objective.objects) do
                local c = server.getCharacterData(obj.id)
                if c then
                    if c.dead then
                        server.notify(-1, "Casualty Died", "A casualty is believed to have died.", 3)
                        mission.data.survivor_dead_count = mission.data.survivor_dead_count + 1
                        return true
                    else
                        local is_in_zone = isPosInZones(server.getObjectPos(obj.id), mission.data.safe_zones)

                        if is_in_zone then
                            if g_savedata.rescued_characters[obj.id] == nil then
                                g_savedata.rescued_characters[obj.id] = 1
                            end

                            local reward = math.floor(objective.reward_value * (0.5 + (c.hp / 200)))
                            server.notify(-1, "Casualty Rescued",
                                "A casualty has been successfully rescued to an safe zone. Rewarded $" .. reward .. ".",
                                4)
                            server.setCurrency(server.getCurrency() + reward, server.getResearchPoints() + 1)
                            return true
                        end
                    end
                end
            end

            return false
        end
    },

    recover_blackbox = {
        start = function(self, mission, objective)
            return true
        end,
        update = function(self, mission, objective, delta_worldtime)
            local vehicle_pos, _ = server.getVehiclePos(objective.object.id)
            local is_in_zone = isPosInZones(vehicle_pos, g_zones_hospital)

            if is_in_zone then
                if objective.reward_value == nil then
                    objective.reward_value = 4500
                end
                server.notify(-1, "Task Complete",
                    "Blackbox has been secured. Rewarded $" .. objective.reward_value .. ".", 4)
                server.setCurrency(server.getCurrency() + objective.reward_value, server.getResearchPoints() + 5)
                return true
            else
                return false
            end
        end
    }
}

g_mission_types = {
    crashed_vehicle = {
        valid_locations = {},

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            local is_mission = parameters.type == "mission"

            if is_mission then
                if mission_objects.main_vehicle_component ~= nil and #mission_objects.survivors > 0 then
                    debugLog("  found location")
                    table.insert(self.valid_locations, {
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor, override_transform, min_range, max_range)
            -- find zone
            local is_ocean_zone = false

            -- only spawn smaller vessels in early game
            if difficulty_factor < 0.5 and location.parameters.size == "size=large" then
                return false
            end
            if difficulty_factor < 0.15 and location.parameters.size == "size=medium" then
                return false
            end

            if location.parameters.vehicle_type == "vehicle_type=boat_ocean" then
                is_ocean_zone = true
            end
            if location.parameters.vehicle_state == "vehicle_state=crash_ocean" then
                is_ocean_zone = true
            end

            local zones =
                findSuitableZones(location.parameters, min_range, max_range, is_ocean_zone, override_transform)

            if #zones > 0 then
                -- select random suitable zone

                local zone_index = math.random(1, #zones)
                local zone = zones[zone_index]

                difficulty_factor = math.max(difficulty_factor, 0)

                local is_transponder = hasTag(location.parameters.capabilities, "transponder") and
                                           (math.random(1, 2) == 1)
                local is_flare = hasTag(location.parameters.capabilities, "flare") and (math.random(1, 2) == 1)
                local is_scuttle = hasTag(location.parameters.capabilities, "scuttle") and (math.random(1, 2) == 1)
                local is_lit = (math.random(1, 3) > 1)
                local is_fire = (math.random(1, 10) <= 5) and (#location.objects.fires > 0)
                local search_radius = 2000 * (math.random(25, 100) / 100)

                -- spawn objects from selected location using zone's world transform
                local spawn_transform = matrix.multiply(zone.transform, matrix.translation(0, -zone.size.y * 0.5, 0))

                -- if zone.parameters.is_arearial then
                -- 	spawn_transform = getRandomPositionInZone(zone,location.parameters)
                -- end
                -- if zone.parameters.location_type=="railroad_both" and math.random(1,10) <= 5 then
                -- 	spawn_transform = matrix.multiply(spawn_transform,matrix.rotationY(math.pi))
                -- end

                local all_mission_objects = {}
                local spawned_objects = {
                    vehicles = spawnObjects(spawn_transform, location, location.objects.vehicles, all_mission_objects,
                        1, 0, 10),
                    survivors = spawnObjects(spawn_transform, location, location.objects.survivors, all_mission_objects,
                        3, 1, 4 + (difficulty_factor * 30)),
                    fires = spawnObjects(spawn_transform, location, location.objects.fires, all_mission_objects, 2, 0,
                        2 + (difficulty_factor * 8)),
                    objects = spawnObjects(spawn_transform, location, location.objects.objects, all_mission_objects, 3,
                        0, 10),
                    vehicle_blackbox = nil
                }

                if location.objects.vehicle_blackbox ~= nil then
                    local rad = math.random(0, 100) / 100 * 2 * math.pi
                    local dis = math.random(5, 20)
                    local blackbox_transform = matrix.multiply(spawn_transform, matrix.translation(math.cos(rad) * dis,
                        0, math.sin(rad) * dis))
                    spawned_objects.vehicle_blackbox = spawnObject(blackbox_transform, location,
                        location.objects.vehicle_blackbox, 0, nil, all_mission_objects)
                end

                local main_vehicle = nil
                for _, vehicle in pairs(spawned_objects.vehicles) do
                    if vehicle.component_id == location.objects.main_vehicle_component.id then
                        main_vehicle = vehicle
                    end
                end

                if main_vehicle == nil or tableLength(spawned_objects.survivors) == 0 then
                    debugLog("ERROR no vehicles or characters spawned")
                    despawnObjects(all_mission_objects, true)
                    return false
                end

                mission.spawned_objects = all_mission_objects
                mission.data = spawned_objects
                mission.data.vehicle_main = main_vehicle

                for survivor_index, survivor_object in pairs(mission.data.survivors) do
                    local is_survivor_injured = math.random(1, 3) == 1

                    if is_survivor_injured then
                        local survivor_health = math.random(60, 90)
                        server.setCharacterData(survivor_object.id, survivor_health, true, false)
                    end

                    survivor_object.bleed_counter = 0
                    survivor_object.is_bleed = is_survivor_injured

                    if is_ocean_zone and (difficulty_factor < 0.5 or math.random(1, 3) == 1) then
                        server.setCharacterItem(survivor_object.id, 2, 23, true, 1, 0)
                    end
                end

                local incoming_disaster = getIncomingDisaster(spawn_transform)

                -- set title and description

                local titles = {}

                if location.parameters.vehicle_type == "vehicle_type=car" then
                    titles = {"A road vehicle incident has been reported", "A vehicle is reported damaged",
                              "A vehicle has gone missing", "A vehicle in distress has been sighted"}
                elseif location.parameters.vehicle_type == "vehicle_type=train" then
                    titles = {"A train incident has been reported", "A train is reported damaged",
                              "A train has gone missing", "A train in distress has been sighted",
                              "A incident has been reported"}
                elseif location.parameters.vehicle_type == "vehicle_type=helicopter" then
                    titles = {"A helicopter crash has been reported", "An aircraft has crashed",
                              "A helicopter has gone missing", "A crashed helicopter has been sighted"}
                elseif location.parameters.vehicle_type == "vehicle_type=plane" then
                    titles = {"A plane crash has been reported", "An aircraft has crashed", "A plane has gone missing",
                              "A crashed plane has been sighted"}
                elseif location.parameters.vehicle_type == "vehicle_type=boat_river" or location.parameters.vehicle_type ==
                    "vehicle_type=boat_ocean" then
                    titles = {"A boat in distress has been reported", "A boat has an emergency",
                              "A boat has gone missing", "A vessel in trouble has been sighted"}
                elseif location.parameters.vehicle_type == "vehicle_type=subs_ocean" or location.parameters.vehicle_type ==
                    "vehicle_type=subs_river" then
                    titles = {"A submersible in distress has been reported", "A submersible has an emergency",
                              "A submersible has gone missing", "A incident has been reported"}
                else
                    titles = {"A vehicle incident has been reported"}
                end

                mission.title = titles[math.random(1, #titles)]

                -- activate transponder

                if is_transponder then
                    search_radius = 4000 * (math.random(35, math.floor(75 + (difficulty_factor * 325))) / 100)

                    mission.desc =
                        "The vehicle has activated its transponder. Use a transponder locator to hone-in on the signal."

                    server.setVehicleTransponder(mission.data.vehicle_main.id, true)
                end

                -- add mission

                addMission(mission)

                -- initialise mission data

                debugLog("adding mission with id " .. mission.id .. "...")

                -- add objectives to the mission

                mission.data.life = g_savedata.mission_life_base
                mission.data.zone = zone
                mission.data.zone_transform = spawn_transform
                mission.data.zone_radius = search_radius
                mission.data.survivor_dead_count = 0
                local radius_offset = mission.data.zone_radius * (math.random(20, 90) / 100)
                local angle = math.random(0, 100) / 100 * 2 * math.pi
                local spawn_transform_x, spawn_transform_y, spawn_transform_z = matrix.position(spawn_transform)
                mission.data.zone_x = spawn_transform_x + radius_offset * math.cos(angle)
                mission.data.zone_z = spawn_transform_z + radius_offset * math.sin(angle)
                mission.data.is_fire = #spawned_objects.fires > 0
                mission.data.is_transponder = is_transponder
                mission.data.is_flare = is_flare
                mission.data.flare_timer = 60 * 30
                mission.data.is_scuttle = is_scuttle
                mission.data.incoming_disaster = incoming_disaster

                -- Natural disasters
                spawnDisaster(mission.data)

                if math.random(1, 2) == 1 or is_transponder then
                    mission.data.state = "locate zone"
                    table.insert(mission.objectives, createObjectiveLocateVehicle(mission.data.vehicle_main.id))

                    if is_transponder then
                        server.notify(-1, "New Mission", mission.title .. " with transponder signal detected.", 0)
                    else
                        server.notify(-1, "New Mission", mission.title .. " without an exact known location.", 0)
                    end
                else
                    mission.data.state = "rescue"
                    self:spawn_location_objectives(mission)
                end

                return true
            end

            return false
        end,

        update = function(self, mission)
            mission.is_important_loaded = server.getVehicleSimulating(mission.data.vehicle_main.id)
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                if server.getObjectSimulating(survivor_object.id) then
                    mission.is_important_loaded = true
                end
            end
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.life > 0 then
                if mission.is_important_loaded == false then
                    mission.data.life = mission.data.life - delta_worldtime
                end

                -- consider launching vehicle flare if flare is set, vehicle is loaded, and timer has timed down

                if mission.data.is_flare then
                    if server.getVehicleSimulating(mission.data.vehicle_main.id) then
                        if mission.data.flare_timer <= 0 then
                            server.pressVehicleButton(mission.data.vehicle_main.id, "mission_flare")
                            mission.data.is_flare = false
                        else
                            mission.data.flare_timer = mission.data.flare_timer - delta_worldtime
                        end
                    end
                end
            else
                -- remove objectives to force mission to end
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
            if mission.data.is_transponder then
                if mission.data.vehicle_main.id == vehicle_id then
                    server.pressVehicleButton(mission.data.vehicle_main.id, "mission_transponder_on")
                end
            end
            if mission.data.vehicle_main.id == vehicle_id then
                if mission.data.is_transponder then
                    server.pressVehicleButton(vehicle_id, "mission_transponder_on")
                end
                if mission.data.is_scuttle and (not mission.data.is_scuttling) then
                    server.pressVehicleButton(vehicle_id, "mission_scuttle_trigger")
                    mission.data.is_scuttling = true
                end
                if mission.data.is_lit then
                    server.pressVehicleButton(vehicle_id, "mission_lights_on")
                end

                if mission.data.seated_character ~= nil then
                    for _, seated in pairs(mission.data.seated_character) do
                        server.setCharacterSeated(seated.character_id, seated.vehicle_id, seated.seat_name)
                    end
                    mission.data.seated_character = nil
                end
            end
        end,

        on_locate = function(self, mission, transform)
            mission.data.state = "rescue"

            if mission.data.is_transponder then
                server.setVehicleTransponder(mission.data.vehicle_main.id, false)
                server.pressVehicleButton(mission.data.vehicle_main.id, "mission_transponder_off")
            end

            self:spawn_location_objectives(mission)
        end,

        rebuild_ui = function(self, mission)
            if mission.data.state == "rescue" then
                local marker_x, marker_y, marker_z = matrix.position(mission.data.zone_transform)
                addMarker(mission, createMarker(marker_x, marker_z, mission.title, mission.desc, 0, 1))
            else
                addMarker(mission, createMarker(mission.data.zone_x, mission.data.zone_z, mission.title, mission.desc,
                    mission.data.zone_radius, 8))
            end
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", "Another rescue service completed this mission.", 2)
            elseif mission.data.survivor_dead_count == 0 then
                server.notify(-1, "Mission Complete", mission.desc, 4)
            else
                server.notify(-1, "Mission Ended", "All unaccounted survivors are believed to have died.", 3)
            end
        end,

        spawn_location_objectives = function(self, mission)
            -- rescue survivors

            local survivor_count = 0
            local survivor_dead_count = 0
            local has_blackbox = false
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                local c = server.getCharacterData(survivor_object.id)
                if c then
                    if c.dead then
                        survivor_dead_count = survivor_dead_count + 1
                        mission.data.survivor_dead_count = mission.data.survivor_dead_count + 1
                    else
                        survivor_count = survivor_count + 1
                        table.insert(mission.objectives, createObjectiveRescueCasualty(survivor_object))
                    end
                end
            end

            if mission.data.vehicle_blackbox ~= nil then
                has_blackbox = true
                table.insert(mission.objectives, createObjectiveRecoverBlackbox(mission.data.vehicle_blackbox))
            end

            -- extinguish fires

            local fire_count = 0
            if mission.data.is_fire then
                for fire_id, fire_object in pairs(mission.data.fires) do
                    fire_count = fire_count + 1
                end

                table.insert(mission.objectives, createObjectiveExtinguishFire(mission.data.fires))
            end

            if survivor_count > 0 and fire_count > 0 then
                mission.desc = "Extinguish fire and rescue " .. survivor_count .. " casualties " ..
                                   mission.data.zone.name .. " to a hospital."
                server.notify(-1, "Casualties and Fire", mission.desc, 0)
            elseif survivor_count > 0 then
                mission.desc = "Rescue " .. survivor_count .. " casualties " .. mission.data.zone.name ..
                                   " to a hospital."
                server.notify(-1, "Casualties", mission.desc, 0)
            elseif fire_count > 0 then
                mission.desc = "Extinguish fire " .. mission.data.zone.name .. "."
                server.notify(-1, "Fire", mission.desc, 0)
            end

            if has_blackbox then
                if title == "" then
                    title = "Find Blackbox"
                end
                mission.desc = table.concat({mission.desc, "find and transport blackbox to the hospital"}, " and ")
            end
        end
    },

    transport = {
        valid_locations = {},

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            local is_mission = parameters.type == "mission_transport"

            if is_mission then
                if #mission_objects.vehicles > 0 or #mission_objects.survivors > 0 or #mission_objects.objects > 0 then
                    debugLog("  found location")
                    table.insert(self.valid_locations, {
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor, override_transform, min_range, max_range)
            -- find zone

            local is_ocean_zone = false
            if location.parameters.source_zone_type == "ocean" then
                is_ocean_zone = true
            end

            local source_parameters = {
                source_zone_type = location.parameters.source_zone_type
            }
            local source_zones = findSuitableZones(source_parameters, min_range, max_range, is_ocean_zone,
                override_transform)

            local dest_parameters = {
                destination_zone_type = location.parameters.destination_zone_type
            }
            local destination_zones = findSuitableZones(dest_parameters, min_range, max_range, is_ocean_zone,
                override_transform)

            if #source_zones > 0 and #destination_zones > 0 then
                -- select random suitable zone

                local source_zone_index = math.random(1, #source_zones)
                local source_zone = source_zones[source_zone_index]

                local destination_zone_index = math.random(1, #destination_zones)
                local destination_zone = destination_zones[destination_zone_index]

                -- spawn objects from selected location using zone's world transform

                local spawn_transform = matrix.multiply(source_zone.transform,
                    matrix.translation(0, -source_zone.size.y * 0.5, 0))
                local all_mission_objects = {}
                local spawned_objects = {
                    vehicles = spawnObjects(spawn_transform, location, location.objects.vehicles, all_mission_objects,
                        3, 0, 10),
                    survivors = spawnObjects(spawn_transform, location, location.objects.survivors, all_mission_objects,
                        3, 0, 4 + (difficulty_factor * 30)),
                    objects = spawnObjects(spawn_transform, location, location.objects.objects, all_mission_objects, 3,
                        0, 10)
                }
                local main_vehicle = nil
                for _, vehicle in pairs(spawned_objects.vehicles) do
                    if vehicle.component_id == location.objects.main_vehicle_component.id then
                        main_vehicle = vehicle
                    end
                end

                if #spawned_objects.vehicles == 0 and #spawned_objects.survivors == 0 and #spawned_objects.objects == 0 then
                    debugLog("ERROR no vehicles or characters or objects spawned")
                    despawnObjects(all_mission_objects, true)
                    return false
                end

                mission.spawned_objects = all_mission_objects
                mission.data = spawned_objects
                mission.data.vehicle_main = main_vehicle

                -- set title and description

                local titles = {"Transport is required."}

                mission.title = titles[math.random(1, #titles)] .. " Destination: " .. destination_zone.name

                mission.desc = titles[math.random(1, #titles)] .. " Destination: " .. destination_zone.name

                -- add mission

                addMission(mission)

                -- initialise mission data

                debugLog("adding mission with id " .. mission.id .. "...")

                -- add objectives to the mission

                mission.data.life = g_savedata.mission_life_base
                mission.data.zone = source_zone
                mission.data.zone_transform = spawn_transform
                mission.data.dest_transform = destination_zone.transform
                mission.data.state = "transport"
                mission.data.survivor_dead_count = 0

                -- transport objective

                local transport_distance = matrix.distance(spawn_transform, destination_zone.transform)
                local reward_distance_factor = math.ceil((transport_distance / 10) * (math.random(5, 12) / 10) / 1000)

                local vehicle_count = 0
                for _, vehicle_object in pairs(mission.data.vehicles) do
                    vehicle_count = vehicle_count + 1
                    table.insert(mission.objectives, createObjectiveTransportVehicle(vehicle_object, destination_zone,
                        2000 * reward_distance_factor))
                end

                local survivor_count = 0
                for _, survivor_object in pairs(mission.data.survivors) do
                    survivor_count = survivor_count + 1
                    table.insert(mission.objectives, createObjectiveTransportCharacter(survivor_object,
                        destination_zone, 2000 * reward_distance_factor))
                end

                local object_count = 0
                for _, object_object in pairs(mission.data.objects) do
                    object_count = object_count + 1
                    table.insert(mission.objectives, createObjectiveTransportObject(object_object, destination_zone,
                        1000 * reward_distance_factor))
                end

                if survivor_count > 0 then
                    mission.desc = titles[math.random(1, #titles)] .. " " .. survivor_count .. " passengers"

                    if vehicle_count > 0 then
                        mission.desc = mission.desc .. " and their vehicle"
                    end

                    if object_count > 0 then
                        mission.desc = mission.desc .. " and their cargo"
                    end

                    mission.desc = mission.desc .. " require transport to " .. destination_zone.name
                elseif vehicle_count > 0 then
                    mission.desc = titles[math.random(1, #titles)] .. " A vehicle needs transporting to " ..
                                       destination_zone.name
                end

                server.notify(-1, "New Mission", mission.title, 0)

                return true
            end

            return false
        end,

        update = function(self, mission)
            mission.is_important_loaded = false
            if mission.data.vehicle_main ~= nil then
                if server.getVehicleSimulating(mission.data.vehicle_main.id) then
                    mission.is_important_loaded = true
                end
            end
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                if server.getObjectSimulating(survivor_object.id) then
                    mission.is_important_loaded = true
                end
            end
            for _, crate in pairs(mission.data.objects) do
                if server.getObjectSimulating(crate.id) then
                    mission.is_important_loaded = true
                end
            end
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.survivor_dead_count > 0 then
                -- a survivor has died end the mission immediately
                mission.objectives = {}
            end

            if mission.data.life > 0 then
                if mission.is_important_loaded == false then
                    mission.data.life = mission.data.life - delta_worldtime
                end
            else
                -- remove objectives to force mission to end
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
        end,

        on_locate = function(self, mission, transform)
        end,

        rebuild_ui = function(self, mission)
            if mission.data.state == "transport" then
                local marker_x, marker_y, marker_z = matrix.position(mission.data.zone_transform)
                addMarker(mission, createMarker(marker_x, marker_z, mission.desc, "", 0, 1))
                local marker_x, marker_y, marker_z = matrix.position(mission.data.dest_transform)
                addMarker(mission, createMarker(marker_x, marker_z, "Destination", "", 0, 0))

                addLineMarker(mission, createLineMarker(mission.data.zone_transform, mission.data.dest_transform, 0.6))
            end
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", "Another rescue service completed this mission.", 2)
            elseif mission.data.survivor_dead_count > 0 then
                server.notify(-1, "Mission Failed", "A passenger has died during transport. This is unacceptable.", 3)
            else
                server.notify(-1, "Mission Complete", mission.desc, 4)
            end
        end
    },

    evacuate = {
        valid_locations = {},

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            local is_mission = parameters.type == "mission_transport"

            if is_mission then
                if #mission_objects.survivors > 0 then
                    debugLog("  found location")
                    table.insert(self.valid_locations, {
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor, override_transform, min_range, max_range)
            -- find zone

            if override_transform == nil then
                return false
            end

            local parameters = {
                is_evacuate = true
            }
            local zones = findSuitableZones(parameters, min_range, max_range, false, override_transform)

            local safe_zones = {}
            local danger_zones = {}

            for _, z in pairs(zones) do
                local dist = matrix.distance(z.transform, override_transform)
                if dist > 4000 then
                    table.insert(safe_zones, z)
                else
                    z.survivor_count = 0
                    table.insert(danger_zones, z)
                end
            end

            if #safe_zones > 0 and #danger_zones > 0 then

                mission.data.safe_zones = safe_zones
                mission.data.danger_zones = danger_zones

                local all_mission_objects = {}
                local survivor_count = 0

                for _, z in pairs(danger_zones) do
                    -- spawn objects from selected location using zone's world transform
                    local spawn_transform = matrix.multiply(z.transform, matrix.translation(0, -z.size.y * 0.5, 0))

                    local spawned_objects = {
                        survivors = spawnObjects(spawn_transform, location, location.objects.survivors,
                            all_mission_objects, 3, 0, 4 + (difficulty_factor * 30))
                    }

                    for _, survivor_object in pairs(spawned_objects.survivors) do
                        survivor_count = survivor_count + 1
                        z.survivor_count = z.survivor_count + 1
                        table.insert(mission.objectives, createObjectiveMoveToZones(survivor_object))
                    end
                end

                if #all_mission_objects == 0 then
                    debugLog("ERROR no characters spawned")
                    despawnObjects(all_mission_objects, true)
                    return false
                end

                -- add mission
                addMission(mission)

                -- initialise mission data
                debugLog("adding mission with id " .. mission.id .. "...")

                -- add objectives to the mission
                mission.data.life = g_savedata.mission_life_base
                mission.data.zone_transform = override_transform
                mission.data.survivor_dead_count = 0
                mission.spawned_objects = all_mission_objects
                mission.data.survivors = all_mission_objects

                -- set title and description
                mission.title = "Evacuate Civillians"
                mission.desc = survivor_count ..
                                   " civillians need evacuating to a safe zone in anticipation of a natural disaster"

                server.notify(-1, "New Mission", mission.title, 0)

                return true
            end

            return false
        end,

        update = function(self, mission)
            mission.is_important_loaded = false
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                if server.getObjectSimulating(survivor_object.id) then
                    mission.is_important_loaded = true
                end
            end
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.life > 0 then
                if mission.is_important_loaded == false then
                    mission.data.life = mission.data.life - delta_worldtime
                end
            else
                -- remove objectives to force mission to end
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
        end,

        on_locate = function(self, mission, transform)
        end,

        rebuild_ui = function(self, mission)
            local remaining_survivors = #mission.data.survivors - mission.data.survivor_dead_count

            for _, z in pairs(mission.data.danger_zones) do
                if z.survivor_count > 0 then
                    local marker_x, marker_y, marker_z = matrix.position(z.transform)
                    addMarker(mission, createMarker(marker_x, marker_z, z.survivor_count ..
                        " civillians need evacuating to a safe zone in anticipation of a natural disaster", "", 0, 1),
                        255, 0, 0, 125)
                end
            end

            for _, z in pairs(mission.data.safe_zones) do
                local marker_x, marker_y, marker_z = matrix.position(z.transform)
                addMarker(mission, createMarker(marker_x, marker_z, "Safe Zone", "", 0, 11), 0, 255, 0, 125)
            end
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", "Another rescue service managed to get the civillians to safety.",
                    2)
            else
                server.notify(-1, "Mission Complete", mission.desc, 4)
            end
        end
    },

    tow_vehicle = {
        valid_locations = {},

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            local is_mission = false
            for _, capability in pairs(parameters.capabilities) do
                if capability == "tow" then
                    is_mission = true
                end
            end

            if is_mission then
                if mission_objects.main_vehicle_component ~= nil then
                    debugLog("  found location")
                    table.insert(self.valid_locations, {
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor, override_transform, min_range, max_range)

            -- only spawn smaller vessels in early game
            if difficulty_factor < 0.5 and location.parameters.size == "size=large" then
                return false
            end
            if difficulty_factor < 0.15 and location.parameters.size == "size=medium" then
                return false
            end

            local is_ocean_zone = false
            if location.parameters.vehicle_type == "vehicle_type=boat_ocean" then
                is_ocean_zone = true
            end

            local source_zones = findSuitableZones(location.parameters, min_range, max_range, is_ocean_zone,
                override_transform)

            local target_destination_zone_type = "destination_parking"
            if location.parameters.vehicle_type == "vehicle_type=boat_ocean" or location.parameters.vehicle_type ==
                "vehicle_type=boat_river" then
                target_destination_zone_type = "destination_dock"
            end
            local dest_parameters = {
                destination_zone_type = target_destination_zone_type
            }
            local destination_zones =
                findSuitableZones(dest_parameters, min_range, max_range, false, override_transform)

            if #source_zones > 0 and #destination_zones > 0 then
                -- select random suitable zone

                local source_zone_index = math.random(1, #source_zones)
                local source_zone = source_zones[source_zone_index]

                local destination_zone_index = math.random(1, #destination_zones)
                local destination_zone = destination_zones[destination_zone_index]

                -- spawn objects from selected location using zone's world transform

                local spawn_transform = matrix.multiply(source_zone.transform,
                    matrix.translation(0, -source_zone.size.y * 0.5, 0))
                local all_mission_objects = {}
                local spawned_objects = {
                    vehicles = spawnObjects(spawn_transform, location, location.objects.vehicles, all_mission_objects,
                        1, 0, 10)
                }
                local main_vehicle = nil
                for _, vehicle in pairs(spawned_objects.vehicles) do
                    if vehicle.component_id == location.objects.main_vehicle_component.id then
                        main_vehicle = vehicle
                    end
                end

                if #spawned_objects.vehicles < 1 then
                    debugLog("ERROR no vehicle spawned")
                    despawnObjects(all_mission_objects, true)
                    return false
                end

                mission.spawned_objects = all_mission_objects
                mission.data = spawned_objects
                mission.data.vehicle_main = main_vehicle

                local is_repair = false
                for _, capability in pairs(location.parameters.capabilities) do
                    if capability == "repair" and math.random(1, 3) == 1 then
                        is_repair = true
                    end
                end

                local incoming_disaster = getIncomingDisaster(spawn_transform)

                -- set title and description
                if location.parameters.vehicle_type == "vehicle_type=car" then
                    titles = {"A car needing repairs requires transport ", "A car has reportedly broken down "}
                elseif location.parameters.vehicle_type == "vehicle_type=helicopter" then
                    titles = {"A helicopter needing repairs requires transport ",
                              "A helicopter has failed a systems check and requires transport "}
                elseif location.parameters.vehicle_type == "vehicle_type=plane" then
                    titles = {"A plane needing repairs requires transport ", "An stranded aircraft needs towing "}
                elseif location.parameters.vehicle_type == "vehicle_type=boat_river" then
                    titles = {"A boat in has become stuck ", "A stranded boat has requested support "}
                elseif location.parameters.vehicle_type == "vehicle_type=boat_ocean" then
                    titles = {"A boat has broken down ", "A stranded boat has requested support "}
                else
                    titles = {"A stranded vehicle has been reported ", "A vehicle is reported to have broken down ",
                              "A vehicle requiring transport has requested aid "}
                end

                mission.title = titles[math.random(1, #titles)] .. source_zone.name
                mission.desc = ""

                if is_repair then
                    mission.desc = mission.desc .. "Repair and "
                end

                mission.desc = mission.desc .. "Transport " .. location.objects.main_vehicle_component.display_name ..
                                   " " .. source_zone.name .. " to " .. destination_zone.name

                -- add mission

                addMission(mission)

                -- initialise mission data

                debugLog("adding mission with id " .. mission.id .. "...")

                -- add objectives to the mission

                mission.data.life = g_savedata.mission_life_base * 4
                mission.data.source_zone = source_zone
                mission.data.zone_transform = spawn_transform
                mission.data.dest_transform = destination_zone.transform
                mission.data.incoming_disaster = incoming_disaster
                mission.data.state = "rescue"

                local transport_distance = matrix.distance(spawn_transform, destination_zone.transform)
                local reward = math.ceil((transport_distance / 10) * (math.random(20, 40) / 10) / 1000) * 1000

                table.insert(mission.objectives, createObjectiveTransportVehicle(main_vehicle, destination_zone, reward))

                if is_repair then
                    table.insert(mission.objectives, createObjectiveRepairVehicle(main_vehicle.id))
                end

                -- Natural disasters
                spawnDisaster(mission.data)

                server.notify(-1, "New Mission", mission.title, 0)

                return true
            end

            return false
        end,

        update = function(self, mission)
            if mission.data.vehicle_main ~= nil then
                mission.is_important_loaded = server.getVehicleSimulating(mission.data.vehicle_main.id)
            else
                mission.is_important_loaded = false
            end
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.life > 0 then
                if mission.is_important_loaded == false then
                    mission.data.life = mission.data.life - delta_worldtime
                end
            else
                -- remove objectives to force mission to end
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
        end,

        on_locate = function(self, mission, transform)
        end,

        rebuild_ui = function(self, mission)
            local vehicle_pos = server.getVehiclePos(mission.data.vehicle_main.id)
            local vehicle_x, vehicle_y, vehicle_z = matrix.position(vehicle_pos)
            addMarker(mission, createMarker(vehicle_x, vehicle_z, mission.desc, "", 0, 1))
            local marker_x, marker_y, marker_z = matrix.position(mission.data.dest_transform)
            addMarker(mission, createMarker(marker_x, marker_z, "Destination", "", 0, 0))

            addLineMarker(mission, createLineMarker(vehicle_pos, mission.data.dest_transform, 0.6))
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", "Another rescue service completed this mission.", 2)
            else
                server.notify(-1, "Mission Complete", mission.desc, 4)
            end
        end
    },

    building = {
        valid_locations = {},

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            local is_mission = parameters.type == "mission_building"

            if is_mission then
                if #mission_objects.fires > 0 and #mission_objects.survivors > 0 then
                    debugLog("  found location building")
                    table.insert(self.valid_locations, {
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor, override_transform, min_range, max_range)

            local spawn_transform = nil

            -- filter range
            local is_in_range = false

            local players = server.getPlayers()

            for player_index, player_object in pairs(players) do
                local tile_transform = server.getTileTransform((server.getPlayerPos(player_object.id)),
                    location.data.tile)
                local distance_to_zone = matrix.distance(tile_transform, (server.getPlayerPos(player_object.id)))

                if distance_to_zone > min_range and distance_to_zone < max_range then
                    is_in_range = true
                    spawn_transform = tile_transform
                end
            end

            if is_in_range then

                local all_mission_objects = {}
                local spawned_objects = {
                    survivors = spawnObjects(spawn_transform, location, location.objects.survivors, all_mission_objects,
                        2, 0, 4 + (difficulty_factor * 30)),
                    fires = spawnObjects(spawn_transform, location, location.objects.fires, all_mission_objects, 1, 0,
                        10),
                    objects = spawnObjects(spawn_transform, location, location.objects.objects, all_mission_objects, 3,
                        0, 10)
                }

                mission.spawned_objects = all_mission_objects
                mission.data = spawned_objects
                mission.data.vehicle_main = nil

                for survivor_index, survivor_object in pairs(mission.data.survivors) do
                    local is_survivor_injured = math.random(1, 3) == 1

                    local c = server.getCharacterData(survivor_object.id)

                    if is_survivor_injured and c.survivor then
                        local survivor_health = math.random(60, 90)
                        server.setCharacterData(survivor_object.id, survivor_health, true, false)
                    end

                    survivor_object.bleed_counter = 0
                    survivor_object.is_bleed = is_survivor_injured
                end

                local fire_transform = nil
                if #location.objects.fires > 0 then
                    fire_transform = matrix.multiply(spawn_transform, location.objects.fires[1].transform)
                end
                if fire_transform == nil then
                    fire_transform = spawn_transform
                end

                local incoming_disaster = getIncomingDisaster(spawn_transform)

                -- set title and description
                if location.parameters.title ~= "" then
                    mission.title = location.parameters.title
                else
                    mission.title = "A building-fire has been reported"
                end

                if location.parameters.description ~= "" then
                    mission.desc = location.parameters.description
                else
                    mission.desc = "Arrive at the location of the fire to deduce the severity."
                end

                -- add mission

                addMission(mission)

                -- initialise mission data

                debugLog("adding mission with id " .. mission.id .. "...")

                -- add objectives to the mission
                mission.data.life = g_savedata.mission_life_base
                mission.data.zone_radius = 100
                mission.data.survivor_dead_count = 0
                local spawn_transform_x, spawn_transform_y, spawn_transform_z = matrix.position(fire_transform)
                mission.data.zone_x = spawn_transform_x
                mission.data.zone_z = spawn_transform_z
                mission.data.incoming_disaster = incoming_disaster
                mission.data.zone_transform = spawn_transform

                mission.data.state = "locate zone"
                table.insert(mission.objectives, createObjectiveLocateZone(fire_transform))

                -- Natural disasters
                spawnDisaster(mission.data)

                server.notify(-1, "New Mission", mission.desc, 0)

                return true
            end

            return false
        end,

        update = function(self, mission)
            mission.is_important_loaded = false
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                if server.getObjectSimulating(survivor_object.id) then
                    mission.is_important_loaded = true
                end
            end
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.life > 0 then
                if mission.is_important_loaded == false then
                    mission.data.life = mission.data.life - delta_worldtime
                end
            else
                -- remove objectives to force mission to end
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
        end,

        on_locate = function(self, mission, transform)
            mission.data.state = "rescue"
            self:spawn_location_objectives(mission)
        end,

        rebuild_ui = function(self, mission)
            addMarker(mission, createMarker(mission.data.zone_x, mission.data.zone_z, mission.title, mission.desc,
                mission.data.zone_radius, 5))
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", "Another rescue service completed this mission.", 2)
            else
                server.notify(-1, "Mission Complete", mission.desc, 4)
            end
        end,

        spawn_location_objectives = function(self, mission)
            -- rescue survivors

            local survivor_count = 0
            local survivor_dead_count = 0
            for survivor_id, survivor_object in pairs(mission.data.survivors) do
                local c = server.getCharacterData(survivor_object.id)
                if c then
                    if c.survivor then
                        if c.is_dead then
                            survivor_dead_count = survivor_dead_count + 1
                            mission.data.survivor_dead_count = mission.data.survivor_dead_count + 1
                        else
                            survivor_count = survivor_count + 1
                            table.insert(mission.objectives, createObjectiveRescueCasualty(survivor_object))
                        end
                    end
                end
            end

            -- extinguish fires
            local fire_count = 0
            for fire_id, fire_object in pairs(mission.data.fires) do
                fire_count = fire_count + 1
            end

            table.insert(mission.objectives, createObjectiveExtinguishFire(mission.data.fires))

            if survivor_count > 0 and fire_count > 0 then
                mission.desc = "Extinguish fire and rescue " .. survivor_count .. " casualties " .. " to a hospital."
                server.notify(-1, "Casualties and Fire", mission.desc, 0)
            elseif survivor_count > 0 then
                mission.desc = "Rescue " .. survivor_count .. " casualties to a hospital."
                server.notify(-1, "Casualties", mission.desc, 0)
            elseif fire_count > 0 then
                mission.desc = "Extinguish the remaining fires."
                server.notify(-1, "Fire", mission.desc, 0)
            end
        end
    },
    clear_area = {
        valid_locations = {},
        probability = 0.5,

        build_valid_locations = function(self, playlist_index, location_index, parameters, mission_objects,
            location_data)
            if parameters.type == "mission" then
                if mission_objects.vehicle_main ~= nil and hasTag(parameters.capabilities, "obstacle") then
                    debugLog("  found location")
                    if parameters.size == "large" then
                        parameters.difficulty = 0.3
                    end
                    table.insert(self.valid_locations, {
                        name = location_data.name,
                        playlist_index = playlist_index,
                        location_index = location_index,
                        data = location_data,
                        objects = mission_objects,
                        parameters = parameters
                    })
                end
            end
        end,

        spawn = function(self, mission, location, difficulty_factor)
            local min_range, max_range, min_travel, max_travel = getMissionDistance(difficulty_factor)

            local source_zone = nil
            local source_zones = {}
            local spawn_zone = nil

            debugLog("start finding zone")
            local availableZones = getAvailableZones(0, max_range, g_clear_areas, nil)

            for _, zone in pairs(availableZones) do
                local is_filter = false
                if location.parameters.vehicle_type == "rock" then
                    if zone.parameters.location_type ~= "land_road" and zone.parameters.location_type ~= "railroad_both" then
                        is_filter = true
                    end
                elseif location.parameters.vehicle_type == "plane" then
                    if zone.parameters.location_type ~= "land_runway" then
                        is_filter = true
                    end
                end

                if zone.obstacle_spawns == nil or #zone.obstacle_spawns == 0 then
                    is_filter = true
                end
                if (not is_filter) then
                    table.insert(source_zones, zone)
                end
            end

            if #source_zones > 0 then
                source_zone = source_zones[math.random(1, #source_zones)]
            end

            if source_zone ~= nil then
                spawn_zone = source_zone.obstacle_spawns[math.random(1, #source_zone.obstacle_spawns)]
                local spawn_transform = matrix.multiply(spawn_zone.transform,
                    matrix.translation(0, -spawn_zone.size.y * 0.5, 0))

                if spawn_zone.parameters.is_arearial then
                    spawn_transform = getRandomPositionInZone(spawn_zone, location.parameters)
                end

                local all_mission_objects = {}
                local spawned_objects = {
                    vehicle_main = spawnObject(spawn_transform, location, location.objects.vehicle_main, 0, nil,
                        all_mission_objects),
                    vehicle_debris = spawnObjects(spawn_transform, location, location.objects.debris,
                        all_mission_objects)
                }

                if spawned_objects.vehicle_main == nil then
                    debugLog("ERROR no vehicle spawned")
                    despawnObjects(all_mission_objects, true)
                    return false
                end

                mission.spawned_objects = all_mission_objects
                mission.data = spawned_objects

                local titles = {"Obstacles block the area"}
                mission.desc = "Move obstacles away"

                if location.parameters.vehicle_type == "plane" then
                    titles = {"A plane has stucked on the runway is reported"}
                    mission.desc = "Tow " .. location.objects.vehicle_main.display_name .. " to get out of runway"
                elseif location.parameters.vehicle_type == "rock" then
                    if source_zone.parameters.location_type == "railroad_both" then
                        titles = {"Rocks has blocked rail road reported"}
                        mission.desc = "Move rocks away from rail road"
                    elseif source_zone.parameters.location_type == "land_road" then
                        titles = {"Rocks has blocked road reported"}
                        mission.desc = "Move rocks away from road"
                    end
                end

                if location.parameters.title ~= "" then
                    mission.title = location.parameters.title .. " " .. source_zone.name
                else
                    mission.title = titles[math.random(1, #titles)] .. " " .. source_zone.name
                end

                addMission(mission)

                debugLog("adding mission with id " .. mission.id .. "...")

                mission.data.life = 60 * 60 * 120
                mission.data.source_zone = source_zone
                mission.data.zone = source_zone
                mission.data.zone_transform = spawn_transform
                mission.data.vehicle_id = spawned_objects.vehicle_main.id
                mission.data.once_in_zone = false
                mission.data.damaged_cargo_count = 0
                mission.is_active = false

                mission.data.state = "rescue"

                local reward = 8000
                table.insert(mission.objectives,
                    createObjectiveTransportOutVehicle(spawned_objects.vehicle_main, source_zone, reward))
                for vehicle_id, vehicle_object in pairs(mission.data.vehicle_debris) do
                    table.insert(mission.objectives,
                        createObjectiveTransportOutVehicle(vehicle_object, source_zone, reward))
                end

                server.notify(-1, "New Mission", mission.title, 0)

                return true
            end

            return false
        end,

        tick = function(self, mission, delta_worldtime)
            if mission.data.life > 0 then
                if (not mission.is_active) then
                    mission.data.life = mission.data.life - delta_worldtime
                end
            else
                mission.objectives = {}
            end
        end,

        on_vehicle_load = function(self, mission, vehicle_id)
        end,

        on_locate = function(self, mission, transform)
        end,

        rebuild_ui = function(self, mission)
            local vehicle_pos = server.getVehiclePos(mission.data.vehicle_id)
            local vehicle_x, vehicle_y, vehicle_z = matrix.position(vehicle_pos)
            addMarker(mission, createSurvivorMarker(vehicle_x, vehicle_z, mission.desc, ""))
        end,

        terminate = function(self, mission)
            if mission.data.life <= 0 then
                server.notify(-1, "Mission Expired", mission.expire_message, 2)
                return false
            else
                server.notify(-1, "Mission Complete", mission.desc, 4)
                return true
            end
        end
    }
}

-------------------------------------------------------------------
--
--	Callbacks
--
-------------------------------------------------------------------

function onCreate(is_world_create)

    -- backwards compatability savedata checking
    if g_savedata.rescued_characters == nil then
        g_savedata.rescued_characters = {}
    end
    if g_savedata.mission_frequency == nil then
        g_savedata.mission_frequency = 60 * 60 * 60
    end
    if g_savedata.mission_life_base == nil then
        g_savedata.mission_life_base = 60 * 60 * 60
    end
    if g_savedata.disasters == nil then
        g_savedata.disasters = {}
    end

    for i in iterPlaylists() do
        for j in iterLocations(i) do
            local parameters, mission_objects = loadLocation(i, j)
            local location_data = server.getLocationData(i, j)
            for mission_type_name, mission_type_data in pairs(g_mission_types) do
                mission_type_data:build_valid_locations(i, j, parameters, mission_objects, location_data)
            end
        end
    end

    g_zones = server.getZones()
    g_zones_hospital = server.getZones("hospital")

    -- filter zones to only include mission zones
    for zone_index, zone_object in pairs(g_zones) do
        local is_mission_zone = false
        for zone_tag_index, zone_tag_object in pairs(zone_object.tags) do
            if zone_tag_object == "type=mission_zone" then
                is_mission_zone = true
            end
        end
        if is_mission_zone == false then
            g_zones[zone_index] = nil
        end
    end
end

function onVehicleDamaged(vehicle_id, amount, x, y, z)
    if g_damage_tracker[vehicle_id] ~= nil then
        g_damage_tracker[vehicle_id] = g_damage_tracker[vehicle_id] + amount
    end

end

function onPlayerJoin(steamid, name, peerid, admin, auth)
    if g_savedata.missions ~= nil then
        for k, mission_data in pairs(g_savedata.missions) do
            for k, marker in pairs(mission_data.map_markers) do
                if marker.archetype == "default" then
                    server.addMapObject(peerid, marker.id, 0, marker.type, marker.x, marker.z, 0, 0, 0, 0,
                        marker.display_label, marker.radius, marker.hover_label)
                elseif marker.archetype == "line" then
                    server.addMapLine(-1, marker.id, marker.start_matrix, marker.dest_matrix, marker.width)
                end
            end
        end
    end
end

function onToggleMap(peer_id, is_open)
    for _, mission in pairs(g_savedata.missions) do
        removeMissionMarkers(mission)
        g_mission_types[mission.type]:rebuild_ui(mission)
    end

    rebuildDisasters()
end

function onTick(delta_worldtime)

    startTime = server.getTimeMillisec()
    math.randomseed(server.getTimeMillisec())

    tickDisasters()

    g_zones_hospital = server.getZones("hospital")

    for char_id, timer in pairs(g_savedata.rescued_characters) do
        if timer <= 180 then
            g_savedata.rescued_characters[char_id] = timer + 1
        end
        if timer == 180 then
            server.setCharacterData(char_id, 100, false, false)
            g_savedata.rescued_characters[char_id] = nil
        end
    end

    local difficulty_factor = getDifficulty()
    local min_range = 2000 + (3000 * difficulty_factor)
    local max_range = 2500 + (30000 * difficulty_factor)

    if server.getTutorial() == false then
        if g_savedata.spawn_counter <= 0 then
            local attempts = 0
            local is_mission_spawn = false
            repeat
                attempts = attempts + 1
                is_mission_spawn = startMission(nil, min_range, max_range, difficulty_factor)
            until is_mission_spawn or attempts > 50

            if is_mission_spawn then
                g_savedata.spawn_counter = g_savedata.mission_frequency
            else
                g_savedata.spawn_counter = 60 * 60 * 5
            end
        else
            g_savedata.spawn_counter = g_savedata.spawn_counter - delta_worldtime
        end
    end

    for _, mission in pairs(g_savedata.missions) do
        local mission_type = g_mission_types[mission.type]
        mission_type:tick(mission, delta_worldtime)

        local objective_count = 0
        local is_mission_ui_modified = false

        g_objective_update_counter = g_objective_update_counter + 1

        for k, objective in pairs(mission.objectives) do
            local objective_type = g_objective_types[objective.type]

            if g_objective_update_counter > 60 then
                if objective_type:update(mission, objective, delta_worldtime) then
                    mission.objectives[k] = nil
                    is_mission_ui_modified = true
                end
            end

            objective_count = objective_count + 1
        end

        if g_objective_update_counter > 60 then
            mission_type:update(mission, delta_worldtime)
            g_objective_update_counter = 0
        end

        if objective_count == 0 then
            mission_type:terminate(mission)
            endMission(mission, false)
        elseif is_mission_ui_modified then
            removeMissionMarkers(mission)
            g_mission_types[mission.type]:rebuild_ui(mission)
        end
    end

    runTime = server.getTimeMillisec() - startTime
    if runTime > 10 then
        server.announce("[def_miss_loc]", "onTick took " .. runTime .. " ms")
    end
end

function onCustomCommand(message, user_id, admin, auth, command, one, two, three, four, five, six, seven, eight, nine,
    ten, eleven, twelve, thirteen, fourteen, fifteen)
    math.randomseed(server.getTimeMillisec())

    local name = server.getPlayerName(user_id)

    if command == "?mstart" and admin == true then
        if one ~= nil and one ~= "" then

            local difficulty_factor = 1.0
            if two ~= nil and two ~= "" then
                difficulty_factor = tonumber(two)
            end

            local min_range = 0
            local max_range = 2500 + (30000 * difficulty_factor)

            if g_mission_types[one] == nil then
                server.announce("[Server]",
                    "Usage: ?mstart {building, tow_vehicle, crashed_vehicle, transport} [difficulty:0-1]")
                return
            end

            server.announce("[Server]", name .. " spawned a mission")

            local attempts = 0
            repeat
                if #g_mission_types[one].valid_locations < 1 then
                    server.announce("[Server]", "No valid locations found for that mission type!")
                    return
                end

                attempts = attempts + 1

                if attempts > 100 then
                    server.announce("[Server]", "No valid locations nearby in 100 attempts.")
                end

                local random_location_value = math.random(1, #g_mission_types[one].valid_locations)

                local mission = createMission(one)

                local is_mission_spawn = g_mission_types[one]:spawn(mission,
                    g_mission_types[one].valid_locations[random_location_value], difficulty_factor, nil, min_range,
                    max_range)

                if is_mission_spawn then
                    g_mission_types[one]:rebuild_ui(mission)
                end
            until is_mission_spawn or attempts > 100
        else
            local difficulty_factor = getDifficulty()
            local min_range = 2000 + (3000 * difficulty_factor)
            local max_range = 2500 + (30000 * difficulty_factor)
            server.announce("[Server]", name .. " spawned a mission")
            startMission(nil, min_range, max_range, difficulty_factor)
        end
    end

    if (command == "?mclean" or command == "?mclear") and admin == true then
        for _, mission in pairs(g_savedata.missions) do
            server.announce("[Server]", "Despawned mission: " .. mission.title)
            endMission(mission, true)
        end
    end

    if admin then

        if command == "?mtest" and admin == true then
            if one ~= nil and one ~= "" then

                local difficulty_factor = 1.0
                if two ~= nil and two ~= "" then
                    difficulty_factor = tonumber(two)
                end

                local min_range = 0
                local max_range = 2500 + (30000 * difficulty_factor)

                if g_mission_types[one] == nil then
                    server.announce("[Server]",
                        "Usage: ?mtest {building, tow_vehicle, crashed_vehicle, transport} {difficulty:0-1} {location_name}")
                    return
                end

                local attempts = 0
                repeat
                    if #g_mission_types[one].valid_locations < 1 then
                        server.announce("[Server]", "No valid locations found for that mission type!")
                        return
                    end

                    attempts = attempts + 1

                    if attempts > 1000 then
                        server.announce("[Server]", "No valid locations nearby in 1000 attempts.")
                    end

                    local location_value = nil

                    for i, loc in pairs(g_mission_types[one].valid_locations) do
                        if loc.data.name == three then
                            location_value = i
                        end
                    end

                    local is_mission_spawn = false

                    if location_value ~= nil then
                        local mission = createMission(one)

                        is_mission_spawn = g_mission_types[one]:spawn(mission,
                            g_mission_types[one].valid_locations[location_value], difficulty_factor, nil, min_range,
                            max_range)

                        if is_mission_spawn then
                            g_mission_types[one]:rebuild_ui(mission)
                        end
                    end
                until is_mission_spawn or attempts > 1000
            else
                server.announce("[Server]",
                    "Usage: ?mtest {building, tow_vehicle, crashed_vehicle, transport} {difficulty:0-1} {location_name}")
            end
        end

        if command == "?log" and admin == true then
            printLog()
        end

        if command == "?printdata" and admin == true then
            server.announce("[Debug]", "---------------")
            printTable(g_savedata, "missions")
            server.announce("", "---------------")
        end

        if command == "?printtables" and admin == true then
            server.announce("[Debug]", "---------------")
            printTable(g_objective_types, "objective types")
            printTable(g_mission_types, "mission types")
            server.announce("", "---------------")
        end

        if command == "?printplaylists" and admin == true then
            for i, data in iterPlaylists() do
                printTable(data, "playlist_" .. i)
            end
        end

        if command == "?printlocations" and admin == true then
            for i, data in iterLocations(tonumber(one) or 0) do
                printTable(data, "location_" .. i)
            end
        end

        if command == "?printobjects" and admin == true then
            for i, data in iterObjects(tonumber(one) or 0, tonumber(two) or 0) do
                printTable(data, "object_" .. i)
            end
        end

        if command == "?printtags" and admin == true then
            local location_tags = {}

            server.announce("", "Begin location tags")

            for i in iterPlaylists() do
                for j in iterLocations(i) do
                    for _, object_data in iterObjects(i, j) do
                        local is_mission_object = false
                        for tag_index, tag_object in pairs(object_data.tags) do
                            if tag_object == "type=mission" then
                                is_mission_object = true
                            end
                        end

                        if is_mission_object then
                            for tag_index, tag_object in pairs(object_data.tags) do
                                if location_tags[tag_object] == nil then
                                    location_tags[tag_object] = 1
                                else
                                    location_tags[tag_object] = location_tags[tag_object] + 1
                                end
                            end
                        end
                    end
                end
            end

            local location_tag_keys = {}
            -- populate the table that holds the keys
            for tag_index, tag_object in pairs(location_tags) do
                table.insert(location_tag_keys, tag_index)
            end
            -- sort the keys
            table.sort(location_tag_keys)
            -- use the keys to retrieve the values in the sorted order
            for _, key in ipairs(location_tag_keys) do
                server.announce(key, location_tags[key])
            end

            server.announce("", "End location tags")

            server.announce("", "Begin zone tags")

            local zone_tags = {}

            for zone_index, zone_object in pairs(g_zones) do
                for zone_tag_index, zone_tag_object in pairs(zone_object.tags) do
                    if zone_tags[zone_tag_object] == nil then
                        zone_tags[zone_tag_object] = 1
                    else
                        zone_tags[zone_tag_object] = zone_tags[zone_tag_object] + 1
                    end
                end
            end

            local zone_tag_keys = {}
            -- populate the table that holds the keys
            for tag_index, tag_object in pairs(zone_tags) do
                table.insert(zone_tag_keys, tag_index)
            end
            -- sort the keys
            table.sort(zone_tag_keys)
            -- use the keys to retrieve the values in the sorted order
            for _, key in ipairs(zone_tag_keys) do
                server.announce(key, zone_tags[key])
            end

            server.announce("", "End zone tags")
        end
    end
end

function onVehicleLoad(vehicle_id)
    for _, mission in pairs(g_savedata.missions) do
        local mission_type = g_mission_types[mission.type]
        mission_type:on_vehicle_load(mission, vehicle_id)
    end
end

-------------------------------------------------------------------
--
--	Mission Logic
--
-------------------------------------------------------------------

function getClosestVolcano(transform)
    local volcanos = server.getVolcanos()
    local closest_dist = 999999999
    local closest_volcano = nil

    for tile, v in pairs(volcanos) do
        local dist = matrix.distance(transform, matrix.translation(v.x, 0, v.z))
        if dist < closest_dist then
            closest_dist = dist
            closest_volcano = v
        end
    end

    return closest_volcano, closest_dist
end

function getIncomingDisaster(transform)

    if g_savedata.disasters == nil then
        return nil
    end

    if #g_savedata.disasters > 0 then
        return nil -- Limit disaster missions to 1 at a time to prevent overlap of evacuation objectives
    end

    local difficulty_factor = getDifficulty()
    local w = server.getWeather(transform)
    local t = server.getTile(transform)
    local is_ocean_zone = t.name == ""

    local closest_volcano, dist = getClosestVolcano(transform)
    if closest_volcano and dist < 2000 and math.random() <= (difficulty_factor * 0.7) + 0.1 then
        return "volcano"
    end

    if math.random() <= (difficulty_factor * 0.3) + 0.1 then
        return "meteor"
    elseif is_ocean_zone and math.random() <= (difficulty_factor * 0.3) + 0.1 then
        return "whirlpool"
    elseif math.random() <= (difficulty_factor * 0.3) + 0.1 then
        return "tsunami"
    elseif w.wind > 70 and math.random() <= (difficulty_factor * 0.9) + 0.1 then
        return "tornado"
    end
    return nil
end

function getDisasterFlavor(incoming_disaster)
    if incoming_disaster == "tornado" then
        return "Extreme wind has been detected on location."
    elseif incoming_disaster == "whirlpool" then
        return "Tectonic disruptions to the seabed are causing unpredictable water currents."
    elseif incoming_disaster == "tsunami" then
        return "Seismic activity has caused large scale ocean displacement, a tsunami warning has been issued."
    elseif incoming_disaster == "meteor" then
        return "Nearby weather stations have detected an incoming impact event."
    elseif incoming_disaster == "volcano" then
        return "Seismic activity in the area has triggered a volcanic response."
    end
    return ""
end

function spawnDisaster(data)
    if data.incoming_disaster ~= nil then
        local radius_offset = 2000 * (math.random(20, 90) / 100)
        local angle = math.random(0, 100) / 100 * 2 * math.pi
        local spawn_transform_x, spawn_transform_y, spawn_transform_z = matrix.position(data.zone_transform)

        local disaster = {
            countdown = 60 * 60 * math.random(30, 60),
            transform = data.zone_transform,
            ui_x = spawn_transform_x + radius_offset * math.cos(angle),
            ui_z = spawn_transform_z + radius_offset * math.sin(angle),
            type = data.incoming_disaster,
            map_markers = {}
        }
        table.insert(g_savedata.disasters, disaster)

        addMarker(disaster, createMarker(disaster.ui_x, disaster.ui_z, "WARNING: EXTREME WEATHER",
            getDisasterFlavor(disaster.type), 4000, 8), 20, 20, 230, 200)

        -- spawn evac mission
        local difficulty_factor = 1.0
        local min_range = 0
        local max_range = 2500 + (30000 * difficulty_factor)

        if #g_mission_types["evacuate"].valid_locations < 1 then
            server.announce("[Server]", "No valid locations found for that mission type!")
            return
        end

        local random_location_value = math.random(1, #g_mission_types["evacuate"].valid_locations)
        local mission = createMission("evacuate")
        local is_mission_spawn = g_mission_types["evacuate"]:spawn(mission,
            g_mission_types["evacuate"].valid_locations[random_location_value], difficulty_factor, data.zone_transform,
            min_range, max_range)
        if is_mission_spawn then
            g_mission_types["evacuate"]:rebuild_ui(mission)
        end
    end
end

function rebuildDisasters()
    if g_savedata.disasters == nil then
        return
    end
    for i, disaster in pairs(g_savedata.disasters) do
        removeMissionMarkers(disaster)
        addMarker(disaster, createMarker(disaster.ui_x, disaster.ui_z, "WARNING: EXTREME WEATHER",
            getDisasterFlavor(disaster.type), 4000, 8), 20, 20, 230, 200)
    end
end

function getDisasterDuration(disaster)
    if disaster.type == "tornado" then
        return 4
    elseif disaster.type == "whirlpool" then
        return 6
    elseif disaster.type == "tsunami" then
        return 6
    elseif disaster.type == "meteor" then
        return 1
    elseif disaster.type == "volcano" then
        return 2
    end
end

function tickDisasters()
    if g_savedata.disasters == nil then
        return
    end

    for i, disaster in pairs(g_savedata.disasters) do
        disaster.countdown = disaster.countdown - 1

        if disaster.countdown == 0 then
            local radius_offset = 1500 + (1000 * math.random())
            local angle = math.random(0, 100) / 100 * 2 * math.pi
            local spawn_transform_x, spawn_transform_y, spawn_transform_z = matrix.position(disaster.transform)
            local offset_spawn = matrix.translation(spawn_transform_x + radius_offset * math.cos(angle), 0,
                spawn_transform_z + radius_offset * math.sin(angle))

            if disaster.type == "tornado" then
                server.spawnTornado(offset_spawn)
            elseif disaster.type == "whirlpool" then
                ocean, is_success = server.getOceanTransform(disaster.transform, 1000, 5000)
                if is_success then
                    server.spawnWhirlpool(ocean, 1)
                end
            elseif disaster.type == "tsunami" then
                ocean, is_success = server.getOceanTransform(disaster.transform, 4000, 8000)
                if is_success then
                    server.spawnTsunami(disaster.transform, 1)
                end
            elseif disaster.type == "meteor" then
                server.spawnMeteorShower(offset_spawn, 1)
            elseif disaster.type == "volcano" then
                local closest_volcano, _ = getClosestVolcano(disaster.transform)
                if closest_volcano then
                    server.spawnVolcano(matrix.translation(closest_volcano.x, 0, closest_volcano.z))
                end
            end
        elseif disaster.countdown == -60 * 60 * getDisasterDuration(disaster) then
            removeMissionMarkers(disaster)
            startMission(disaster.transform, 2000, 4000, getDifficulty())
            startMission(disaster.transform, 2000, 4000, getDifficulty())
            g_savedata.disasters[i] = nil
        end
    end
end

function getDifficulty()
    local mission_difficulty_factor = 1
    if server.getGameSettings().no_clip == false then
        mission_difficulty_factor = math.min(1, server.getDateValue() / 60)
    end
    return mission_difficulty_factor
end

function startMission(override_transform, min_range, max_range, mission_difficulty_factor)
    g_output_log = {}

    local mission_type_location_count = 0;
    local mission_type_location_probability_count = 0;

    for mission_type_name, mission_type_data in pairs(g_mission_types) do
        for location_index, location_data in pairs(mission_type_data.valid_locations) do
            mission_type_location_count = mission_type_location_count + 1
            mission_type_location_probability_count = mission_type_location_probability_count +
                                                          location_data.parameters.probability
        end
    end

    if mission_type_location_count > 0 then
        local random_location_value = math.random(0, math.floor(mission_type_location_probability_count * 100)) / 100

        local selected_mission_type_name = nil
        local selected_mission_type_data = nil
        local selected_mission_location_index = nil

        for mission_type_name, mission_type_data in pairs(g_mission_types) do
            for location_index, location_data in pairs(mission_type_data.valid_locations) do
                if random_location_value > location_data.parameters.probability then
                    random_location_value = random_location_value - location_data.parameters.probability
                else
                    if selected_mission_type_name == nil then
                        selected_mission_type_name = mission_type_name
                        selected_mission_type_data = mission_type_data
                        selected_mission_location_index = location_index
                    end
                end
            end
        end

        if selected_mission_type_data ~= nil then
            local mission = createMission(selected_mission_type_name)

            local is_mission_spawn = selected_mission_type_data:spawn(mission,
                selected_mission_type_data.valid_locations[selected_mission_location_index], mission_difficulty_factor,
                override_transform, min_range, max_range)

            if is_mission_spawn then
                selected_mission_type_data:rebuild_ui(mission)
            end

            return is_mission_spawn
        end
    end

    return false
end

-- removes a mission from the global mission container and cleans up its spawned objects and UI
function endMission(mission, force_despawn)
    if mission ~= nil then
        removeMissionMarkers(mission)

        despawnObjects(mission.spawned_objects, force_despawn)

        for k, mission_data in pairs(g_savedata.missions) do
            if mission_data.id == mission.id then
                g_savedata.missions[k] = nil
            end
        end
    end
end

-------------------------------------------------------------------
--
--	Mission Creation
--
-------------------------------------------------------------------

function getAvailableZones(min_range, max_range, zone_list, parameters)
    local is_ocean_zone = isOceanCase(parameters)
    if zone_list == nil then
        zone_list = g_zones
    end

    local ret = {}
    local min_range_pow = min_range * min_range
    local max_range_pow = max_range * max_range
    local purchasedTiles = getPurchasedZones()
    local t = 0

    for zone_index, zone_object in pairs(zone_list) do
        local filter = false
        filter = filterZones(zone_object.parameters, parameters)
        if (not filter) then
            t = t + 1
            local failed = false
            for player_index, player_object in pairs(g_players) do
                local distance_to_zone = sqrDistance(server.getPlayerPos(player_object.id), zone_object.transform)

                if distance_to_zone < 1000000 then
                    failed = true
                    break
                end
            end
            if (not failed) then
                failed = true
                for spawn_index, spawn_obj in pairs(purchasedTiles) do
                    local distance_to_zone = sqrDistance(spawn_obj.transform, zone_object.transform)
                    if (distance_to_zone < max_range_pow) then
                        failed = false
                    end
                end
            end
            if (not failed) then
                for _, mission in pairs(g_savedata.missions) do
                    local distance_to_zone = sqrDistance(mission.data.zone.transform, zone_object.transform)
                    if distance_to_zone < 1000000 then
                        failed = true
                        break
                    end
                end
            end
            if (not failed) then
                table.insert(ret, zone_object)
            end
        end
    end
    debugLog("AvailableZones: " .. #ret .. "/" .. t .. "(" .. #zone_list .. ")")
    return ret
end

function getPurchasedZones()
    local ret = {}
    local spawn_type = {}
    for spawn_index, spawn_obj in pairs(g_spawns) do
        local is_purchased = server.getTilePurchased(spawn_obj.transform)
        if is_purchased then
            for _, tag_object in pairs(spawn_obj.tags) do
                if string.find(tag_object, "spawn_type=") ~= nil then
                    local type_temp = string.sub(tag_object, 12)
                    if (not hasTag(spawn_type, type_temp)) then
                        table.insert(spawn_type, type_temp)
                    end
                end
            end
            table.insert(ret, spawn_obj)
        end
    end
    return ret, spawn_type
end

function getMissionDistance(difficulty_factor)
	return 1500 + (500 * difficulty_factor),2000 + (28000 * difficulty_factor),1500 + (1500 * difficulty_factor),3000 + (27000 * difficulty_factor)
end

function getRandomPositionInZone(zone_data,parameters)
	local x_limit = zone_data.size.x
	local z_limit = zone_data.size.z
	if parameters.size == "small" then
		x_limit = x_limit - 7
		z_limit = z_limit - 7
	elseif parameters.size == "medium" then
		x_limit = x_limit - 20
		z_limit = z_limit - 20
	elseif parameters.size == "large" then
		x_limit = x_limit - 50
		z_limit = z_limit - 50
	else
		x_limit = 10
		z_limit = 10
	end

	if x_limit < 0 then
		x_limit = 0
	end
	if z_limit < 0 then
		z_limit = 0
	end
	
	return matrix.multiply(zone_data.transform,matrix.translation(math.random(-50,50)/100*x_limit,0,math.random(-50,50)/100*z_limit))
end

function findSuitableZones(parameters, min_range, max_range, is_ocean_zone, override_transform)

    local zones = {}

    if is_ocean_zone and math.random(1, 2) == 1 then
        -- get random player to search for ocean zone near

        local players = server.getPlayers()
        local random_player = players[math.random(1, #players)]
        local spawn_pos = server.getPlayerPos(random_player.id)

        if override_transform ~= nil then
            spawn_pos = override_transform
        end

        local ocean_transform, is_ocean_found = server.getOceanTransform(spawn_pos, min_range, max_range)

        if is_ocean_found then
            -- generate a zone in the ocean

            local zone_object = {
                name = "in the ocean",
                transform = matrix.multiply(ocean_transform,
                    matrix.translation(math.random(-750, 750), 0, math.random(-750, 750))),
                size = {
                    x = 1,
                    y = 1,
                    z = 1
                },
                radius = 1,
                type = 0,
                tags = {"size=large", "location_type=ocean", "theme=oil", "theme=fishing"}
            }

            table.insert(zones, zone_object)
        end
    else
        -- find a suitable zone from the list of existing zones

        for zone_index, zone_object in pairs(g_zones) do
            -- filter range
            local is_in_range = false

            if override_transform ~= nil then
                local distance_to_zone = matrix.distance(override_transform, zone_object.transform)
                if distance_to_zone > min_range and distance_to_zone < max_range then
                    is_in_range = true
                end
            else
                local players = server.getPlayers()
                for player_index, player_object in pairs(players) do
                    local distance_to_zone = matrix.distance(server.getPlayerPos(player_object.id),
                        zone_object.transform)

                    if distance_to_zone > min_range and distance_to_zone < max_range then
                        is_in_range = true
                        break
                    end
                end
            end

            if is_in_range then
                local is_filter = false

                if parameters.is_evacuate and (hasTag(zone_object.tags, "evacuation") == false) then
                    break
                end

                -- filter size
                if parameters.size == "size=small" then
                    if hasTag(zone_object.tags, "size=small") == false and hasTag(zone_object.tags, "size=medium") ==
                        false and hasTag(zone_object.tags, "size=large") == false then
                        break
                    end
                elseif parameters.size == "size=medium" then
                    if hasTag(zone_object.tags, "size=medium") == false and hasTag(zone_object.tags, "size=large") ==
                        false then
                        break
                    end
                elseif parameters.size == "size=large" then
                    if hasTag(zone_object.tags, "size=large") == false then
                        break
                    end
                end

                if is_ocean_zone then
                    if hasTag(zone_object.tags, "location_type=ocean") == false and
                        hasTag(zone_object.tags, "location_type=ocean_bridge") == false and
                        hasTag(zone_object.tags, "location_type=ocean_iceberg") == false and
                        hasTag(zone_object.tags, "location_type=ocean_rocks") == false and
                        hasTag(zone_object.tags, "location_type=ocean_shore") == false then
                        break
                    end
                else

                    -- filter theme
                    if parameters.theme ~= nil and parameters.theme ~= "" then
                        if hasTag(zone_object.tags, parameters.theme) == false then
                            if parameters.theme ~= "theme=civilian" then
                                break
                            end
                        end
                    end

                    -- filter by vehicle type
                    if parameters.vehicle_type == "vehicle_type=car" then
                        if parameters.theme == "theme=camp" then
                            if hasTag(zone_object.tags, "location_type=land_road") == false and
                                hasTag(zone_object.tags, "location_type=land_forest") == false and
                                hasTag(zone_object.tags, "location_type=land_shore") == false and
                                hasTag(zone_object.tags, "location_type=land") == false and
                                hasTag(zone_object.tags, "location_type=land_offroad") == false then
                                break
                            end
                        else
                            if hasTag(zone_object.tags, "location_type=land_road") == false then
                                break
                            end
                        end
                    elseif parameters.vehicle_type == "vehicle_type=helicopter" then
                        if hasTag(zone_object.tags, "location_type=land_forest") == false and
                            hasTag(zone_object.tags, "location_type=land_shore") == false and
                            hasTag(zone_object.tags, "location_type=land_road") == false and
                            hasTag(zone_object.tags, "location_type=land_helipad") == false then
                            break
                        end
                    elseif parameters.vehicle_type == "vehicle_type=plane" then
                        if hasTag(zone_object.tags, "location_type=land_forest") == false and
                            hasTag(zone_object.tags, "location_type=land_shore") == false and
                            hasTag(zone_object.tags, "location_type=land_road") == false and
                            hasTag(zone_object.tags, "location_type=land_runway") == false then
                            break
                        end
                    elseif parameters.vehicle_type == "vehicle_type=boat_river" then
                        if hasTag(zone_object.tags, "location_type=ocean_river") == false then
                            break
                        end
                    elseif parameters.vehicle_type == "vehicle_type=boat_ocean" then
                        -- handled in is_ocean_zone case
                    elseif parameters.vehicle_type == "vehicle_type=plane_ocean" then
                        -- handled in is_ocean_zone case
                    end
                end

                if parameters.source_zone_type ~= nil and parameters.source_zone_type ~= "" then
                    if hasTag(zone_object.tags, "zone_type=" .. parameters.source_zone_type) == false then
                        break
                    end
                end

                if parameters.destination_zone_type ~= nil and parameters.destination_zone_type ~= "" then
                    if hasTag(zone_object.tags, "zone_type=" .. parameters.destination_zone_type) == false then
                        break
                    end
                end

                if is_filter == false then
                    table.insert(zones, zone_object)
                end
            end
        end
    end

    return zones
end

function loadLocation(playlist_index, location_index)

    local mission_objects = {
        main_vehicle_component = nil,
        vehicles = {},
        survivors = {},
        fires = {},
        objects = {}
    }

    local parameters = {
        type = "",
        size = "",
        theme = "",
        vehicle_type = "",
        vehicle_state = "",
        source_zone_type = "",
        destination_zone_type = "",
        probability = 1,
        capabilities = {},
        title = "",
        description = ""
    }

    for _, object_data in iterObjects(playlist_index, location_index) do
        -- investigate tags
        local is_tag_object = false
        for tag_index, tag_object in pairs(object_data.tags) do
            if tag_object == "type=mission" then
                is_tag_object = true
                parameters.type = "mission"
            end
            if tag_object == "type=mission_transport" then
                is_tag_object = true
                parameters.type = "mission_transport"
            end
            if tag_object == "type=mission_building" then
                is_tag_object = true
                parameters.type = "mission_building"
            end
        end

        if is_tag_object then
            for tag_index, tag_object in pairs(object_data.tags) do
                if string.find(tag_object, "size=") ~= nil then
                    parameters.size = tag_object
                elseif string.find(tag_object, "theme=") ~= nil then
                    parameters.theme = tag_object
                elseif string.find(tag_object, "vehicle_type=") ~= nil then
                    parameters.vehicle_type = tag_object
                elseif string.find(tag_object, "vehicle_state=") ~= nil then
                    parameters.vehicle_state = tag_object
                elseif string.find(tag_object, "probability=") ~= nil then
                    parameters.probability = tonumber(string.sub(tag_object, 13))
                elseif string.find(tag_object, "source_zone_type=") ~= nil then
                    parameters.source_zone_type = string.sub(tag_object, 18)
                elseif string.find(tag_object, "destination_zone_type=") ~= nil then
                    parameters.destination_zone_type = string.sub(tag_object, 23)
                elseif string.find(tag_object, "capability=") ~= nil then
                    table.insert(parameters.capabilities, string.sub(tag_object, 12))
                elseif string.find(tag_object, "title=") ~= nil then
                    parameters.title = string.sub(tag_object, 7)
                elseif string.find(tag_object, "description=") ~= nil then
                    parameters.description = string.sub(tag_object, 13)
                end
            end
        end

        if object_data.type == "vehicle" then
            table.insert(mission_objects.vehicles, object_data)
            if mission_objects.main_vehicle_component == nil and hasTag(object_data.tags, "type=mission") then
                mission_objects.main_vehicle_component = object_data
            end
        elseif object_data.type == "character" then
            table.insert(mission_objects.survivors, object_data)
        elseif object_data.type == "fire" then
            table.insert(mission_objects.fires, object_data)
        elseif object_data.type == "object" then
            table.insert(mission_objects.objects, object_data)
        end
    end

    return parameters, mission_objects
end

-- creates an empty mission and assigns it a unique id
function createMission(mission_type_name)
    g_savedata.id_counter = g_savedata.id_counter + 1

    return {
        id = g_savedata.id_counter,
        type = mission_type_name,
        spawned_objects = {},
        data = {},
        map_markers = {},
        objectives = {},
        title = "",
        desc = "",
        is_important_loaded = false
    }
end

-- adds a mission to the global mission container and notifies players that it is available
function addMission(mission)
    g_savedata.missions[mission.id] = mission

    g_savedata.spawn_counter = 60 * 60 * math.random(30, 120)
end

-------------------------------------------------------------------
--
--	Mission Objective Behaviour
--
-------------------------------------------------------------------

function createObjective()
    return {
        type = "",
        objects = {},
        transform = {}
    }
end

function createObjectiveLocateZone(zone_transform)
    local objective = createObjective()

    objective.type = "locate_zone"
    objective.transform = zone_transform

    return objective
end

function createObjectiveLocateVehicle(vehicle_id)
    local objective = createObjective()

    objective.type = "locate_vehicle"
    objective.vehicle_id = vehicle_id

    return objective
end

function createObjectiveRescueCasualty(survivor)
    local objective = createObjective()

    objective.type = "rescue_casualty"
    table.insert(objective.objects, survivor)
    objective.reward_value = 4000

    return objective
end

function createObjectiveExtinguishFire(fires)
    local objective = createObjective()

    objective.type = "extinguish_fire"
    objective.objects = fires
    objective.reward_value = 3000

    return objective
end

function createObjectiveRepairVehicle(vehicle_id)
    local objective = createObjective()

    objective.type = "repair_vehicle"
    objective.vehicle_id = vehicle_id
    objective.reward_value = 3500
    objective.damaged = false

    return objective
end

function createObjectiveTransportCharacter(object, destination, reward)
    local objective = createObjective()

    objective.type = "transport_character"
    table.insert(objective.objects, object)
    objective.destination = destination
    objective.reward_value = reward

    return objective
end

function createObjectiveTransportVehicle(object, destination, reward)
    local objective = createObjective()

    objective.type = "transport_vehicle"
    table.insert(objective.objects, object)
    objective.destination = destination
    objective.reward_value = reward

    return objective
end

function createObjectiveTransportObject(object, destination, reward)
    local objective = createObjective()

    objective.type = "transport_object"
    table.insert(objective.objects, object)
    objective.destination = destination
    objective.reward_value = reward

    return objective
end

function createObjectiveMoveToZones(survivor)
    local objective = createObjective()

    objective.type = "move_to_zones"
    table.insert(objective.objects, survivor)
    objective.reward_value = 4500

    return objective
end

function createObjectiveRecoverBlackbox(object)
    local objective = createObjective()

    objective.type = "recover_blackbox"
    objective.object = object
    objective.reward_value = 4000

    return objective
end

function createObjectiveTransportOutVehicle(object,source,reward)
	local objective = createObjective()

	objective.type = "transport_vehicle"
	table.insert(objective.objects,object)
	objective.object_count = 1
	objective.destination = source
	objective.invert = true
	objective.reward_value = reward

	return objective
end
-------------------------------------------------------------------
--
--	Mission UI
--
-------------------------------------------------------------------

-- adds a marker to a mission
function addMarker(mission_data, marker_data, r, g, b, a)
    marker_data.archetype = "default"
    table.insert(mission_data.map_markers, marker_data)
    server.addMapObject(-1, marker_data.id, 0, marker_data.type, marker_data.x, marker_data.z, 0, 0, 0, 0,
        marker_data.display_label, marker_data.radius, marker_data.hover_label, r, g, b, a)
end

function addLineMarker(mission_data, marker_data)
    marker_data.archetype = "line"
    table.insert(mission_data.map_markers, marker_data)
    server.addMapLine(-1, marker_data.id, marker_data.start_matrix, marker_data.dest_matrix, marker_data.width)
end

function createMarker(x, z, display_label, hover_label, radius, icon)
    local map_id = server.getMapID()

    return {
        id = map_id,
        type = icon,
        x = x,
        z = z,
        radius = radius,
        display_label = display_label,
        hover_label = hover_label
    }
end

function createLineMarker(start_matrix, dest_matrix, width)
    local map_id = server.getMapID()

    return {
        id = map_id,
        start_matrix = start_matrix,
        dest_matrix = dest_matrix,
        width = width
    }
end

-------------------------------------------------------------------
--
--	Utility Functions
--
-------------------------------------------------------------------

-- spawn a list of object descriptors from a playlist location.
-- playlist_index is required to spawn vehicles from the correct playlist.
-- a table of spawned object data is returned, as well as the data being appended to an option out_spawned_objects table
function spawnObjects(spawn_transform, location, object_descriptors, out_spawned_objects, spawn_rarity, min_amount,
    max_amount)
    local spawned_objects = {}

    for _, object in pairs(object_descriptors) do
        if ((#spawned_objects < min_amount) or (math.random(1, spawn_rarity) == 1)) and #spawned_objects < max_amount then
            -- find parent vehicle id if set
            local parent_vehicle_id = 0
            if object.vehicle_parent_component_id > 0 then
                for spawned_object_id, spawned_object in pairs(out_spawned_objects) do
                    if spawned_object.type == "vehicle" and spawned_object.component_id ==
                        object.vehicle_parent_component_id then
                        parent_vehicle_id = spawned_object.id
                    end
                end
            end
            spawnObject(spawn_transform, location, object, parent_vehicle_id, spawned_objects, out_spawned_objects)
        end
    end

    debugLog("spawned " .. #spawned_objects .. "/" .. #object_descriptors .. " objects")

    return spawned_objects
end

function spawnObject(spawn_transform, location, object, parent_vehicle_id, spawned_objects, out_spawned_objects)
    -- spawn object

    local spawned_object_id = spawnObjectType(spawn_transform, location, object, parent_vehicle_id)

    -- add object to spawned object tables

    if spawned_object_id ~= nil and spawned_object_id ~= 0 then
        local object_data = {
            type = object.type,
            id = spawned_object_id,
            component_id = object.id
        }

        if spawned_objects ~= nil then
            table.insert(spawned_objects, object_data)
        end

        if out_spawned_objects ~= nil then
            table.insert(out_spawned_objects, object_data)
        end

        return object_data
    end

    return nil
end

-- spawn an individual object descriptor from a playlist location
function spawnObjectType(spawn_transform, location, object_descriptor, parent_vehicle_id)
    local component = server.spawnAddonComponent(matrix.multiply(spawn_transform, object_descriptor.transform),
        location.playlist_index, location.location_index, object_descriptor.index, parent_vehicle_id)
    return component.id
end

-- despawn all objects in the list
function despawnObjects(objects, is_force_despawn)
    if objects ~= nil then
        for _, object in pairs(objects) do
            despawnObject(object.type, object.id, is_force_despawn)
        end
    end
end

-- despawn a specific object by type and id.
-- if is_force_despawn is true, the object will be instantly removed, otherwise it will be removed when it despawns naturally
function despawnObject(type, id, is_force_despawn)
    if type == "vehicle" then
        server.despawnVehicle(id, is_force_despawn)
    elseif type == "character" then
        server.despawnObject(id, is_force_despawn)
    elseif type == "fire" then
        server.despawnObject(id, is_force_despawn)
    elseif type == "object" then
        server.despawnObject(id, is_force_despawn)
    end
end

-- returns a table of all spawned object data in objects that is matched by the callback function
function filterSpawnedObjects(objects, callback_filter)
    local filtered_objects = {}

    for k, obj in pairs(objects) do
        if callback_filter(obj) then
            table.insert(filtered_objects, obj)
        end
    end

    return filtered_objects
end

-- gets all mission zones for which the callback_filter function returns true.
-- callback_filter must be a function that takes a single parameter which is a table containing a list of zone tags to test against
function getMissionZones(callback_filter)
    debugLog("getting zones...")

    local zones = server.getZones(callback_filter)

    if zones == nil or tableLength(zones) == 0 then
        debugLog("ERROR failed to find matching zones")
        return nil
    end

    debugLog("found " .. tableLength(zones) .. " zones")
    return zones
end

-- checks if a position is contained with any zone in a list of zones returned by server.getZones
function isPosInZones(transform, zones)
    for k, v in pairs(zones) do
        if server.isInTransformArea(transform, v.transform, v.size.x, v.size.y, v.size.z) then
            return true
        end
    end

    return false
end

-- checks if a specific tag string appears in a table of tag strings
function hasTag(tags, tag)
    for k, v in pairs(tags) do
        if v == tag then
            return true
        end
    end

    return false
end

-- calculates the size of non-contiguous tables and tables that use non-integer keys
function tableLength(T)
    local count = 0
    for _ in pairs(T) do
        count = count + 1
    end
    return count
end

-- recursively outputs the contents of a table to the chat window for debugging purposes.
-- name is the name that should be displayed for the root of the table being passed in.
-- m is an optional parameter used when the function recurses to specify a margin string that will be prepended before printing for readability
function printTable(table, name, m)
    local margin = m or ""

    if tableLength(table) == 0 then
        server.announce("", margin .. name .. " = {}")
    else
        server.announce("", margin .. name .. " = {")

        for k, v in pairs(table) do
            local vtype = type(v)

            if vtype == "table" then
                printTable(v, k, margin .. "    ")
            elseif vtype == "string" then
                server.announce("", margin .. "    " .. k .. " = \"" .. tostring(v) .. "\",")
            elseif vtype == "number" or vtype == "function" or vtype == "boolean" then
                server.announce("", margin .. "    " .. k .. " = " .. tostring(v) .. ",")
            else
                server.announce("", margin .. "    " .. k .. " = " .. tostring(v) .. " (" .. type(v) .. "),")
            end
        end

        server.announce("", margin .. "},")
    end
end

-- pushes a string into the global output log table.
-- the log is cleared when a new mission is spawned.
-- the log for the previously spawned mission can be displayed using the command ?log
function debugLog(message)
    table.insert(g_output_log, message)
end

-- outputs everything in the debug log to the chat window
function printLog()
    for i = 1, #g_output_log do
        server.announce("[Debug Log] " .. i, g_output_log[i])
    end
end

-- iterator function for iterating over all playlists, skipping any that return nil data
function iterPlaylists()
    local playlist_count = server.getAddonCount()
    local playlist_index = 0

    return function()
        local playlist_data = nil
        local index = playlist_count

        while playlist_data == nil and playlist_index < playlist_count do
            playlist_data = server.getAddonData(playlist_index)
            index = playlist_index
            playlist_index = playlist_index + 1
        end

        if playlist_data ~= nil then
            return index, playlist_data
        else
            return nil
        end
    end
end

-- iterator function for iterating over all locations in a playlist, skipping any that return nil data
function iterLocations(playlist_index)
    local playlist_data = server.getAddonData(playlist_index)
    local location_count = 0
    if playlist_data ~= nil then
        location_count = playlist_data.location_count
    end
    local location_index = 0

    return function()
        local location_data = nil
        local index = location_count

        while location_data == nil and location_index < location_count do
            location_data = server.getLocationData(playlist_index, location_index)
            index = location_index
            location_index = location_index + 1
        end

        if location_data ~= nil then
            return index, location_data
        else
            return nil
        end
    end
end

-- iterator function for iterating over all objects in a location, skipping any that return nil data
function iterObjects(playlist_index, location_index)
    local location_data = server.getLocationData(playlist_index, location_index)
    local object_count = 0
    if location_data ~= nil then
        object_count = location_data.component_count
    end
    local object_index = 0

    return function()
        local object_data = nil
        local index = object_count

        while object_data == nil and object_index < object_count do
            object_data = server.getLocationComponentData(playlist_index, location_index, object_index)
            object_data.index = object_index
            index = object_index
            object_index = object_index + 1
        end

        if object_data ~= nil then
            return index, object_data
        else
            return nil
        end
    end
end

function addMarker(mission_data,marker_data)
	marker_data.archetype = "default"
	table.insert(mission_data.map_markers,marker_data)
	if mission_data.is_active then
		server.addMapObject(-1,marker_data.id,0,marker_data.type,marker_data.x,marker_data.z,0,0,0,0,marker_data.display_label,marker_data.radius,marker_data.hover_label.."\n(active)")
	else
		local remainTimeAllSec = mission_data.data.life/60
		local remainTimeMin = math.ceil(remainTimeAllSec/60)
		local remainTimeSec = math.ceil(remainTimeAllSec%60)
		server.addMapObject(-1,marker_data.id,0,marker_data.type,marker_data.x,marker_data.z,0,0,0,0,marker_data.display_label,marker_data.radius,marker_data.hover_label.."\n("..remainTimeMin..":"..remainTimeSec..")")
	end
end

function addLineMarker(mission_data,marker_data)
	marker_data.archetype = "line"
	table.insert(mission_data.map_markers,marker_data)
	server.addMapLine(-1,marker_data.id,marker_data.start_matrix,marker_data.dest_matrix,marker_data.width)
end

function createZoneMarker(radius,x,z,display_label,hover_label)
	local map_id = server.getMapID()

	return { 
		id = map_id,
		type = 8,
		x = x,
		z = z,
		radius = radius,
		display_label = display_label,
		hover_label = hover_label 
	}
end

function createSurvivorMarker(x,z,display_label,hover_label)
	local map_id = server.getMapID()

	return { 
		id = map_id,
		type = 1,
		x = x,
		z = z,
		radius = 0,
		display_label = display_label,
		hover_label = hover_label 
	}
end

function createDeliveryMarker(x,z,display_label,hover_label)
	local map_id = server.getMapID()

	return { 
		id = map_id,
		type = 0,
		x = x,
		z = z,
		radius = 0,
		display_label = display_label,
		hover_label = hover_label 
	}
end

function createLineMarker(start_matrix,dest_matrix,width)
	local map_id = server.getMapID()

	return { 
		id = map_id,
		start_matrix = start_matrix,
		dest_matrix = dest_matrix,
		width = width
	}
end


function removeMissionMarkers(mission)
    for k, obj in pairs(mission.map_markers) do
        server.removeMapID(-1, obj.id)
    end
    mission.map_markers = {}
end
