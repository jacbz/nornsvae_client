-- NornsVAE
-- jacob zhang
--
--
-- E1: interpolation slider
-- E2: attribute selector
-- E3: attribute slider
--
-- K1: reload fresh sequences
-- K2: edit left sequence
-- K3: edit right sequence
--
-- Grid: edit patterns
--
-- instruments:
-- - ride cymbal
-- - crash cymbal
-- - high tom
-- - low tom
-- - open hi-hat
-- - closed hi-hat
-- - snare drum
-- - bass drum
--
-- attributes:
-- - DS (density)
-- - BD (bass drum)
-- - SD (snare drum)
-- - HH (hi-hats)
-- - TO (toms)
-- - CY (cymbals)

Ack = require "ack/lib/ack"
engine.name = "Ack"

util = require "util"
json = include("lib/json")
MusicUtil = require "musicutil"

local grid = util.file_exists(_path.code .. "midigrid") and include "midigrid/lib/mg_128" or grid

server_ip = util.os_capture("cat " .. _path.code .. "nornsvae_client/server-ip")
server = "http://" .. server_ip .. "/"

total_steps = 16
bpm = 100
params:set("clock_tempo", bpm)
steps_per_beat = 4
step_length = 1 / 4

initialized = false
connection_lost = false

-- current sequence
current_step = 1
current_pad_sequence = "left"

-- attribute vectors
mode = 1
modes = {
  "DS",
  "BD",
  "SD",
  "HH",
  "TO",
  "CY"
}
mode_min = -4
mode_max = 4
mode_current_step = {0, 0, 0, 0, 0, 0}

-- interpolation
interpolation_steps = 11
current_interpolation = 1
lookahead = {}

-- server communication
job_id = nil
trigger_lookahead_at_next_step = false -- when setting this to true, a lookahead call will be triggered at the next step
trigger_replace_at_step = nil -- when setting this to a step, a replace call will be triggered at that step

-- logging
current_log = ""

-- midi
midi_device = {}
midi_device_names = {}
target = 2
for i = 1, #midi.vports do
  midi_device[i] = midi.connect(i)
  local full_name =
    table.insert(midi_device_names, "port " .. i .. ": " .. util.trim_string_to_width(midi_device[i].name, 40))
end
params:add_option("midi target", "midi target", midi_device_names, 1)
params:set_action(
  "midi target",
  function(x)
    target = x
  end
)
drum_midi_notes = {
  51, -- Ride Cymbal 1
  49, -- Crash Cymbal 1
  50, -- High Tom
  45, -- Low Tom
  46, -- Open Hi-hat
  42, -- Closed Hi-hat
  38, -- Acoustic Snare
  36 -- Electric Bass Drum
}

function log(type, data)
  entry = {
    type = type,
    data = data,
    time = util.time()
  }
  if string.len(current_log) ~= 0 then
    current_log = current_log .. ";"
  end
  current_log = current_log .. json.encode(entry)
end

function server_init()
  return util.os_capture("curl -g -s '" .. server .. "init?time=" .. util.time() .. "' --max-time 0.5")
end

function server_log()
  local response = util.os_capture("curl -g -s '" .. server .. "log?data=" .. current_log .. "' --max-time 0.5")
  if response == "OK" then
    current_log = ""
  end
end

function server_sync()
  local response = util.os_capture("curl -g -s " .. server .. "sync" .. " --max-time 0.5")
  if string.len(response) == 0 then
    connection_lost = true
    return
  end
  if string.len(response) > 2 then
    local parsedResponse = json.decode(response)
    if job_id == parsedResponse.job_id then
      lookahead = parsedResponse.data
      job_id = nil
    end
  end
end

function server_lookahead()
  local attr_values = json.encode(mode_current_step)
  local attribute = modes[mode]
  job_id =
    util.os_capture(
    "curl -g -s '" ..
      server .. "lookahead?attr_values=" .. attr_values .. "&attribute=" .. attribute .. "' --max-time 0.5"
  )
end

function server_replace()
  local dict1 = json.encode(lookahead[tostring(0)][attr_values_str()])
  local dict2 = json.encode(lookahead[tostring(interpolation_steps - 1)][attr_values_str()])
  job_id =
    util.os_capture("curl -g -s '" .. server .. "replace?dict1=" .. dict1 .. "&dict2=" .. dict2 .. "' --max-time 0.5")
  mode_current_step = {0, 0, 0, 0, 0, 0}
end

function server_reload()
  mode_current_step = {0, 0, 0, 0, 0, 0}
  job_id = util.os_capture("curl -g -s " .. server .. "reload --max-time 0.5")
end

function get_current_sample()
  return lookahead[tostring(current_interpolation - 1)][attr_values_str()]
end

function get_current_notes()
  local dict = get_current_sample()
  if dict then
    return dict.notes
  else
    print("Error: interpolation " .. tostring(current_interpolation - 1) .. " not found for " .. attr_values_str())
    trigger_lookahead_at_next_step = true -- hotfix?
    return {}
  end
end

function get_current_pad_notes()
  local interpolation = current_pad_sequence == "left" and 1 or interpolation_steps
  local dict = lookahead[tostring(interpolation - 1)][attr_values_str()]
  if dict then
    return dict.notes
  else
    print("Error: interpolation " .. tostring(interpolation - 1) .. " not found for " .. attr_values_str())
    trigger_lookahead_at_next_step = true -- hotfix?
    return {}
  end
end

function attr_values_str()
  local strings = {}
  for i, val in ipairs(mode_current_step) do
    table.insert(strings, modes[i] .. string.format("%+d", val))
  end
  return table.concat(strings, ", ")
end

function load_drum_samples()
  sample_directory = _path.code .. "nornsvae_client/audio/"
  samples = {
    "1.wav",
    "2.wav",
    "3.wav",
    "4.wav",
    "5.wav",
    "6.wav",
    "7.wav",
    "8.wav"
  }
  for i, name in pairs(samples) do
    engine.loadSample(i - 1, sample_directory .. name)
  end
end

function init()
  load_drum_samples()

  redraw()

  clock.run(
    function()
      log("init_client", {})

      print("Server: " .. server)

      local init_response = ""
      while init_response ~= "OK" do
        print("Attempting to contact server " .. server)
        init_response = server_init()
        clock.sleep(1 / 2)
      end
      print("Server init success")

      server_lookahead()
      while next(lookahead) == nil do
        server_sync()
        clock.sleep(1 / 2)
      end

      initialized = true
      redraw()

      -- SERVER STUFF
      clock.run(handle_server)
      -- SEQUENCE STUFF
      clock.run(step)
    end
  )
end

function handle_server()
  while true do
    clock.sync(step_length)

    if connection_lost then
      return
    end

    if trigger_lookahead_at_next_step then
      trigger_lookahead_at_next_step = false
      server_lookahead()
    end

    if trigger_replace_at_step ~= nil and current_step == (trigger_replace_at_step % total_steps) then
      trigger_replace_at_step = nil
      server_replace()
    end

    if job_id ~= nil and current_step % 2 == 0 then
      server_sync()
    end

    -- send log
    if current_step == 1 and string.len(current_log) > 0 then
      server_log()
    end
  end
end

function step()
  while true do
    clock.sync(step_length)

    if connection_lost then
      redraw()
      return
    end

    local notes = get_current_notes()

    local notes_at_step = notes[tostring(current_step - 1)]

    midiAllOff()

    if notes_at_step then
      for i, note in pairs(notes_at_step) do
        engine.trig(note - 1)
        midi_device[target]:note_on(drum_midi_notes[note], 100, 10)
      end
    end

    current_step = current_step + 1
    if current_step > total_steps then
      current_step = 1
    end
    redraw()

    grid_redraw()
  end
end

function key(n, z)
  -- key actions: n = number, z = state

  if z ~= 1 then
    return
  end

  log(
    "key_press",
    {
      key = n
    }
  )

  if n == 1 then
    server_reload()
  elseif n == 2 then
    current_pad_sequence = "left"
  elseif n == 3 then
    current_pad_sequence = "right"
  end
end

function enc(n, d)
  -- encoder actions: n = number, d = delta
  if n == 1 then
    m = util.clamp(current_interpolation + d, 1, interpolation_steps)
    if m ~= current_interpolation then
      current_interpolation = m
      log(
        "change_interpolation",
        {
          step = current_interpolation
        }
      )
    end
  elseif n == 2 then
    m = util.clamp(mode + d, 1, #modes)
    if m ~= mode then
      mode = m
      trigger_lookahead_at_next_step = true
      log(
        "change_mode",
        {
          mode = mode
        }
      )
    end
  elseif n == 3 then
    m = util.clamp(mode_current_step[mode] + d, mode_min, mode_max)
    if m ~= mode_current_step[mode] then
      mode_current_step[mode] = m
      log(
        "change_mode_step",
        {
          mode = mode,
          step = mode_current_step[mode]
        }
      )
    end
  end
  redraw()
end

function draw_sample(sample, offsetX, offsetY)
  if sample ~= nil then
    screen.pixel(sample["x"] + offsetX, sample["y"] + offsetY)
    screen.fill()
  end
end

function redraw()
  screen.clear()

  if connection_lost then
    screen.move(0, 20)
    screen.level(15)
    screen.text("Connection lost, restart script")
    screen.update()
    return
  end

  if not initialized then
    screen.move(0, 20)
    screen.level(15)
    screen.text("Connecting to server...")
    screen.update()
    return
  end

  if job_id ~= nil then
    screen.level(4)
    screen.move(0, 10)
    screen.font_size(8)
    screen.text("LOADING")
  end

  local gridX = 4
  local gridY = 6
  for step = 1, total_steps do
    for pitch = 1, 8 do
      screen.level(step == current_step and 15 or 1)
      screen.pixel((step - 1) * 4 + gridX + 1, gridY + pitch * 5 + 1)
      screen.fill()
    end
  end

  local notes = get_current_notes()
  for step = 1, total_steps do
    local notes_at_step = notes[tostring(step - 1)]
    if notes_at_step then
      for i, note in pairs(notes_at_step) do
        level = (current_step >= step and current_step < step + 1) and 15 or 4
        screen.level(level)
        screen.rect((step - 1) * 4 + gridX, gridY + note * 5, 3, 3)
        screen.fill()
      end
    end
  end

  -- map
  local left = 128 - 50
  local top = 1
  screen.level(8)
  screen.rect(left, top, 50, 50)
  screen.stroke()

  for step = 1, interpolation_steps do
    screen.level(step == current_interpolation and 15 or 4)
    draw_sample(lookahead[tostring(step - 1)][attr_values_str()], left, top)
  end

  -- divider line
  screen.level(2)
  screen.move(0, 55)
  screen.line_rel(128, 0)
  screen.stroke()

  -- interpolation progress bar
  screen.level(15)
  screen.move((current_interpolation - 1) * (128 / interpolation_steps), 55)
  screen.line_rel(128 / interpolation_steps, 0)
  screen.stroke()

  -- attribute vector modes
  screen.move(0, 62)
  for m = 1, #modes do
    local mode_name = modes[m]

    screen.level(mode == m and 15 or 4)
    screen.text(mode_name .. string.format("%+d", mode_current_step[m]))
    screen.move_rel(3, 0)
  end

  screen.update()
end

grid_redraw = function()
  g:all(0)
  local pad_notes = get_current_pad_notes()
  for step = 1, total_steps do
    local notes_at_step = pad_notes[tostring(step - 1)]
    if notes_at_step then
      for i, note in pairs(notes_at_step) do
        level = (current_step == step) and 15 or 4
        --screen.level(level)
        if step < 17 then
          g:led(step, note, level)
        end
      end
    end
  end
  g:refresh()
end

g = grid.connect()

g.key = function(x, y, z)
  if (z ~= 1) then
    return
  end
  toggleDrum(x, y)
end

function toggleDrum(x, y)
  local notes = get_current_pad_notes()
  if notes[tostring(x - 1)] == nil then
    notes[tostring(x - 1)] = {}
  end

  get_current_sample().hash = nil

  -- if note already exists, toggle off
  for i, note in pairs(notes[tostring(x - 1)]) do
    if note == y then
      table.remove(notes[tostring(x - 1)], i)
      trigger_replace_at_step = current_step + 4

      log(
        "pattern_edit",
        {
          action = "toggle_off",
          current_pad_sequence = current_pad_sequence,
          step = x,
          pitch = y
        }
      )
      return
    end
  end

  -- toggle on
  table.insert(notes[tostring(x - 1)], y)
  trigger_replace_at_step = current_step + 4
  log(
    "pattern_edit",
    {
      action = "toggle_on",
      current_pad_sequence = current_pad_sequence,
      step = x,
      pitch = y
    }
  )
end

function midiAllOff()
  for note = 1, #drum_midi_notes do
    midi_device[target]:note_off(drum_midi_notes[note], 100, 10)
  end
end
