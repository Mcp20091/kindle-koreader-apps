--[==[--
The one template Home Assistant renders for every refresh: all the entities
the plugin can show or control (with only the attributes it uses), each
room's sensors (temperature, humidity, doors, leaks...; only those in a
room), every battery (phones left out), a 3D printer's sensors, Plex's
server sensor, Scan clients button and library sensors (who's watching:
each "w:<user - player>" attribute), each
room's temperature and humidity (a sensor with a humidity sensor on the same
device first, so a thermostat or room sensor wins over, say, a 3D printer's
nozzle), open doors, low batteries (phones left out) and the weather.

{ v, now, e = [[id, name, state, area, device, changed, [[attr, value]...]]...],
  r = [[room, floor, temp, humidity]...], d = [[door, since]...],
  b = [[name, percent]...], w = [state, temp, unit, id, humidity, wind, wind unit],
  ws = [[id, name]...] (every weather entity, for picking one) }
]==]

local Template = {}

Template.ALL = [==[
{%- set doms = ['light','switch','fan','climate','lock','cover','vacuum','media_player','camera','scene','script','input_boolean','calendar'] -%}
{%- set sclasses = ['temperature','humidity','battery','power','energy','illuminance','carbon_dioxide','pm25','pressure','voltage','current','moisture'] -%}
{%- set bclasses = ['door','window','garage_door','opening','motion','occupancy','presence','moisture','smoke','gas','carbon_monoxide','safety','problem','lock','plug','light','sound'] -%}
{%- set keep = ['unit_of_measurement','brightness','supported_color_modes','color_temp_kelvin','min_color_temp_kelvin','max_color_temp_kelvin','entity_id','percentage','percentage_step','preset_mode','preset_modes','oscillating','hvac_modes','hvac_action','current_temperature','temperature','target_temp_low','target_temp_high','target_temp_step','min_temp','max_temp','fan_mode','fan_modes','current_humidity','current_position','device_class','supported_features','source','source_list','volume_level','is_volume_muted','media_title','media_artist','app_name','battery_level','status','message','start_time','all_day','color_mode','hs_color'] -%}
{%- set ns = namespace(e=[], r=[], d=[], b=[]) -%}
{%- set mob = integration_entities('mobile_app') -%}
{%- set plx = integration_entities('plex') | reject('match', 'media_player|update') | list -%}
{%- set pkw = 'flashforge|bambu|prusa|creality|octoprint|klipper|moonraker|3d_printer|ender_?3|ad5m|elegoo|anycubic|voron' -%}
{%- for s in states if s.domain in doms or (s.domain == 'sensor' and s.attributes.device_class in sclasses and (area_name(s.entity_id) or (s.attributes.device_class == 'battery' and s.entity_id not in mob))) or (s.domain == 'binary_sensor' and s.attributes.device_class in bclasses and area_name(s.entity_id)) or (s.domain in ['sensor', 'binary_sensor', 'button'] and s.entity_id | regex_search(pkw)) or s.entity_id in plx -%}
{%- set dn = device_attr(s.entity_id, 'name_by_user') or device_attr(s.entity_id, 'name') or '' -%}
{%- set at = namespace(l=[]) -%}
{%- for k in keep if s.attributes[k] is defined and s.attributes[k] is not none -%}{%- set at.l = at.l + [[k, s.attributes[k]]] -%}{%- endfor -%}
{%- if s.entity_id in plx -%}{%- set at.l = at.l + [['plex', 1]] -%}{%- for k in s.attributes.keys() if k not in keep + ['friendly_name', 'icon', 'last_added_item', 'last_added_timestamp'] -%}{%- set at.l = at.l + [[('library_type' if k == 'library_type' else 'w:' ~ k), s.attributes[k] | string]] -%}{%- endfor -%}{%- endif -%}
{%- set ns.e = ns.e + [[s.entity_id, s.name, s.state, area_name(s.entity_id) or '', dn, as_timestamp(s.last_changed) | int, at.l]] -%}
{%- endfor -%}
{%- set fl = namespace(l=[]) -%}{%- for f in floors() -%}{%- set fl.l = fl.l + floor_areas(f) -%}{%- endfor -%}
{%- for a in fl.l + (areas() | reject('in', fl.l) | list) -%}
{%- set t = namespace(v=none, h=none, best=false) -%}
{%- for e in area_entities(a) if e.startswith('sensor.') and is_state_attr(e, 'device_class', 'temperature') and states(e) | is_number -%}
{%- set hums = device_entities(device_id(e) or '') | select('is_state_attr', 'device_class', 'humidity') | list if device_id(e) else [] -%}
{%- if t.v is none or (hums and not t.best) -%}{%- set t.v = states(e) | float -%}{%- set t.best = hums | count > 0 -%}{%- set t.h = (states(hums[0]) | float(none)) if hums else none -%}{%- endif -%}
{%- endfor -%}
{%- set ns.r = ns.r + [[area_name(a), floor_name(area_id(a)) or '', t.v, t.h]] -%}
{%- endfor -%}
{%- for s in states.binary_sensor if s.attributes.device_class in ['door', 'window', 'garage_door', 'opening'] and s.state == 'on' -%}{%- set ns.d = ns.d + [[s.name, as_timestamp(s.last_changed) | int]] -%}{%- endfor -%}
{%- for s in states.sensor if s.attributes.device_class == 'battery' and s.state | is_number and 0 < s.state | float < 20 and s.entity_id not in mob -%}{%- set ns.b = ns.b + [[s.name, s.state | float | round]] -%}{%- endfor -%}
{%- set w = states.weather | first -%}
{%- set wl = namespace(l=[]) -%}{%- for s in states.weather -%}{%- set wl.l = wl.l + [[s.entity_id, s.name]] -%}{%- endfor -%}
{{ {'v': 1, 'ws': wl.l, 'now': now().timestamp() | int, 'e': ns.e, 'r': ns.r, 'd': ns.d, 'b': ns.b, 'w': [w.state, w.attributes.temperature, w.attributes.temperature_unit, w.entity_id, w.attributes.humidity, w.attributes.wind_speed, w.attributes.wind_speed_unit] if w else none} | to_json }}]==]

--- The template with the weather from `weather` (an entity id; the first
-- weather entity when not set or gone).
function Template.all(weather)
    if not weather or weather == "" then return Template.ALL end
    local id = weather:gsub("[^%w_%.]", "")
    return (Template.ALL:gsub("{%%%- set w = states%.weather | first %-%%}",
        "{%%- set w = (expand('" .. id .. "') | first) or (states.weather | first) -%%}"))
end

--- The state and last change of a few entities (the doorbell, looked at every
-- few seconds): [[state, changed]...] in the order given.
function Template.states(ids)
    local quoted = {}
    for i, id in ipairs(ids) do quoted[i] = "'" .. id:gsub("[^%w_%.]", "") .. "'" end
    return "{%- set ns = namespace(l=[]) -%}{%- for id in [" .. table.concat(quoted, ",") .. "] -%}"
        .. "{%- set s = expand(id) | first -%}"
        .. "{%- set ns.l = ns.l + [[s.state if s else 'unavailable', (as_timestamp(s.last_changed) | int) if s else 0]] -%}"
        .. "{%- endfor -%}{{ ns.l | to_json }}"
end

return Template
