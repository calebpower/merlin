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

  # Zones each carry their own size, and leaving requires travelling further
  # than arriving did. The Python had ONE 0.25-mile constant serving as every
  # geofence radius and as the phone-to-vehicle distance, with no hysteresis at
  # all -- which was survivable only because the away path was dead code.
  #
  # Coordinates are approximate placeholders. Replace with the real ones before
  # cutover; nothing here is a secret, but nothing here is right either.
  zones: [
    %{id: :home, center: {35.9606, -83.9207}, radius: {400, :ft}, hysteresis: 1.25},
    %{id: :work, center: {35.9132, -84.3110}, radius: {0.25, :mi}},
    %{id: :gym, center: {35.9401, -83.9951}, radius: {600, :ft}}
  ],

  # Separate from any zone radius: "is the car with my phone" is a different
  # question from "how big is my house".
  colocation_distance: {0.25, :mi},

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

    # --- the phone, via POST /snitch (mobile_device.py) --------------------
    # Not a broker topic: an API key resolves to this string and the payload is
    # injected as though it had arrived on it. The source cannot tell.
    #
    # This is bug 1 from the survey, fixed at the boundary. mobile_device.py
    # stored the raw payload STRING, and user_location.py then subscripted it
    # as a dict -- raising TypeError inside a fire-and-forget task on every
    # single phone update, silently. Decoding to structured facts at ingest
    # makes that class of error unrepresentable.
    %{
      id: :phone,
      topic: "http/mobile/ariia/state",
      decode: :json,
      facts: [
        %{path: [:person, :caleb, :lat], from: [["gps_latitude"]]},
        %{path: [:person, :caleb, :lon], from: [["gps_longitude"]]},
        %{path: [:person, :caleb, :accuracy_m], from: [["gps_accuracy"]]},
        %{path: [:person, :caleb, :battery_pct], from: [["battery_level"]]}
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

  derived: [
    # --- the geofences ------------------------------------------------------
    # Modules, because this is geometry. Zone definitions are data, because
    # they are facts about your house.
    %{
      id: :caleb_presence,
      kind: :geofence,
      lat: [:person, :caleb, :lat],
      lon: [:person, :caleb, :lon],
      accuracy: [:person, :caleb, :accuracy_m],
      max_accuracy_m: 100,
      out: [:person, :caleb, :zone],
      out_position: [:person, :caleb, :position],
      # A phone silent for half an hour is not evidence of being anywhere.
      # The Python recorded a checkin timestamp and never read it.
      stale_after_ms: 1_800_000
    },
    %{
      id: :vehicle_presence,
      kind: :geofence,
      lat: [:vehicle, :car, :lat],
      lon: [:vehicle, :car, :lon],
      accuracy: [:vehicle, :car, :accuracy_m],
      max_accuracy_m: 100,
      out: [:vehicle, :car, :zone],
      out_position: [:vehicle, :car, :position],
      stale_after_ms: 1_200_000
    },

    # --- daylight -----------------------------------------------------------
    %{id: :sun, kind: :sun, lat: 35.9606, lon: -83.9207, out: [:sun, :state]},

    # --- the vehicle question, as data -------------------------------------
    # Your decision at planning: departure-without-phone as the primary signal,
    # motion-while-parked as a fast path. Both are declared here as facts about
    # the world; whether either is worth waking you up is a rule's business.
    #
    # NOTE: neither carries a sustained-for window yet. "true for two minutes
    # before it counts" needs a timer, and timers arrive with the gen_statem
    # executors at M5. Until then these are twitchier than they should be,
    # which is why both alerting rules below log rather than notify.
    %{
      id: :vehicle_with_phone,
      kind: :expr,
      out: [:vehicle, :car, :with_phone?],
      compute: "within?(vehicle.car.position, person.caleb.position, 402.34)"
    },
    %{
      id: :vehicle_unaccounted,
      kind: :expr,
      out: [:vehicle, :car, :unaccounted?],
      compute: "unknown?(vehicle.car.zone) and vehicle.car.with_phone? == false"
    },
    %{
      id: :vehicle_away_while_home,
      kind: :expr,
      out: [:vehicle, :car, :away_while_home?],
      compute: "person.caleb.zone == :home and vehicle.car.zone != :home"
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

    # --- presence -----------------------------------------------------------
    # The rule that has NEVER fired in production. user_location.py:124 wrote
    # "" where False was meant and every consumer tested `is False`, so this
    # path was dead code for the life of the Python daemon. It executes for the
    # first time here.
    #
    # Your decision: sustained absence, not the instant the flag flips. The
    # sustained-for window needs a timer (M5); until then hysteresis on the
    # zone boundary is what stops it flapping, which is the larger half of the
    # problem anyway.
    %{
      id: :lamps_off_when_away,
      desc: "When I leave, turn the living room lamps off.",
      on: [{:leaves, [:person, :caleb, :zone], :home}],
      # Only on a real departure. Leaving :home for :unknown means we lost the
      # phone, not that you went out.
      when: "defined?(person.caleb.zone)",
      do: [{:set_group, :living_room_lamps, :off}]
    },

    # Your decision: on ARRIVAL, and only after dark. `enters` is an edge, so
    # this cannot fire merely because you are already home.
    %{
      id: :lamps_on_when_arriving_after_dark,
      desc: "Turn the living room lamps on when I arrive home after dark.",
      on: [{:enters, [:person, :caleb, :zone], :home}],
      when: "sun.state == :night",
      do: [{:set_group, :living_room_lamps, :on}]
    },

    # --- the vehicle --------------------------------------------------------
    # Pointed at :log deliberately. These fire on paths with no operational
    # history, and without the M5 hold windows they will be twitchy. Watch the
    # log for a fortnight, then swap :log for a notifier.
    %{
      id: :vehicle_unaccounted_alert,
      desc: "Log when the car is in no known zone and not with my phone.",
      on: [{:enters, [:vehicle, :car, :unaccounted?], true}],
      do: [{:log, :warning, "vehicle unaccounted for: not in a known zone and not with the phone"}]
    },
    %{
      id: :vehicle_away_while_home_alert,
      desc: "Log when I am home and the car is not.",
      on: [{:enters, [:vehicle, :car, :away_while_home?], true}],
      do: [{:log, :warning, "vehicle is away while I am home"}]
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
