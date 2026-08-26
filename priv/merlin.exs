# merlin: the house, as data.
#
# Evaluated to a plain map at boot and validated before anything starts. This
# file is executable by construction -- see Merlin.Config.File -- so it lives
# root-owned at a fixed path and contains no secrets. Secrets arrive in
# merlin.secrets.exs (M3) and via the environment.
#
# Everything here is what the Python kept in eleven hook classes.

%{
  # Overridden by MERLIN_BROKER_HOST / MERLIN_BROKER_PORT, which is how the
  # reaper session and the rc.d script both point it somewhere without editing
  # this file.
  mqtt: %{host: "localhost", port: 1883},

  # Log every effect instead of performing it. Ships TRUE: the first thing this
  # daemon does on the real broker should be to tell you what it would have
  # done. Three of the rules it replaces have never fired in production.
  dry_run: true,

  groups: [
    # What livingroom_lamps.py had implicitly: two per-lamp state topics it
    # tracked, and one zigbee2mqtt *group* topic it published to. Naming it
    # means the toggle rule generalises to N lamps and never sees a topic.
    %{
      id: :living_room_lamps,
      members: [
        [:lamp, :living_room, :one, :power],
        [:lamp, :living_room, :two, :power]
      ],
      set_topic: "zigbee2mqtt/living_room_lamps/set",
      encode: {:json_state, %{on: "ON", off: "OFF"}}
    }
  ],

  sources: [
    # --- liveness harness (echo.py) ---------------------------------------
    %{
      id: :ping,
      topic: "test/ping",
      decode: :raw,
      events: [%{path: [:diag, :ping]}]
    },
    %{
      id: :state_update,
      topic: "state/update",
      decode: :raw,
      facts: [%{path: [:system, :last_message]}]
    },

    # --- living room lamps (livingroom_lamps.py) --------------------------
    # The Python cached lamp state in instance variables initialised to "OFF",
    # so it was optimistically wrong until a retained message arrived. These
    # are facts: absent until observed, and absent is not "off".
    %{
      id: :lamp_one,
      topic: "zigbee2mqtt/home/living_room/plug/lamp_1",
      decode: :json,
      facts: [
        %{
          path: [:lamp, :living_room, :one, :power],
          from: [["state"]],
          codec: {:enum, %{"ON" => :on, "OFF" => :off}}
        }
      ]
    },
    %{
      id: :lamp_two,
      topic: "zigbee2mqtt/home/living_room/plug/lamp_2",
      decode: :json,
      facts: [
        %{
          path: [:lamp, :living_room, :two, :power],
          from: [["state"]],
          codec: {:enum, %{"ON" => :on, "OFF" => :off}}
        }
      ]
    },

    # --- living room button (livingroom_button.py) ------------------------
    # An EVENT, not a fact. The Python wrote time.time() floats here purely to
    # defeat its own value-equality dedup; that hack has nowhere to live now.
    %{
      id: :living_room_button,
      topic: "zigbee2mqtt/home/living_room/switch/lamps/action",
      decode: :raw,
      events: [
        %{
          path: [:button, :living_room, :pressed],
          codec: {:enum, %{"single" => :single, "double" => :double}}
        }
      ]
    },

    # --- doors (home_doors.py) --------------------------------------------
    # One source covers every room. The Python hand-rolled a `+` matcher to
    # achieve this and stored the result as a JSON string containing a list of
    # single-key objects; these are per-room facts.
    #
    # Payload alternatives, in the Python's priority order: `contact` truthy
    # means CLOSED (zigbee2mqtt's convention), else `state == "ON"` means OPEN.
    %{
      id: :doors,
      topic: "home/+room/sensor/contact",
      decode: :json,
      facts: [
        %{
          path: [:door, {:capture, "room"}, :contact],
          from: [["contact"]],
          codec: {:truthy, :closed, :open}
        },
        %{
          path: [:door, {:capture, "room"}, :contact],
          from: [["state"]],
          codec: {:enum, %{"ON" => :open, "OFF" => :closed}}
        }
      ]
    }
  ],

  rules: [
    # --- echo parity -------------------------------------------------------
    # Moved out of the adapter and into data, as promised at M1. The adapter
    # now only ingests; answering is policy and policy is a rule.
    %{
      id: :ping_pong,
      desc: "Answer a ping with a pong. The liveness harness.",
      on: [{:receives, [:diag, :ping]}],
      do: [{:publish, "test/pong", "pong"}]
    },

    # --- living room lamps -------------------------------------------------
    %{
      id: :lamps_toggle,
      desc: "A single press toggles the living room lamps: off only when both are on.",
      on: [{:receives, [:button, :living_room, :pressed]}],
      when: "trigger.value == :single",
      do: [
        {:set_group, :living_room_lamps,
         {:expr, "if(all_eq?(:living_room_lamps, :on), :off, :on)"}}
      ]
    },

    # Your decision at planning: double press is a hard off, where the Python
    # had both presses doing exactly the same thing.
    %{
      id: :lamps_hard_off,
      desc: "A double press turns the living room lamps off, whatever they were doing.",
      on: [{:receives, [:button, :living_room, :pressed]}],
      when: "trigger.value == :double",
      do: [{:set_group, :living_room_lamps, :off}]
    },

    # --- doors -------------------------------------------------------------
    # The presence edge home_doors.py faked with a time.time() timestamp. It is
    # an event now, and it names the room -- which the Python's generic
    # "Unexpected presence detected at home!" alert could not.
    %{
      id: :door_presence,
      desc: "A door changing state is a presence event, naming the room.",
      on: [{:changes_under, [:door]}],
      do: [{:log, :info, {:expr, "to_s(trigger.value)"}}]
    }
  ]
}
