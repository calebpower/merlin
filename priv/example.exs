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

  # 1880, which is the port the phone has been posting to for years. The plan
  # assumed 8080; the machine said otherwise. Changing the phone is a change to
  # something I cannot test, so the daemon moves instead.
  api: %{port: 1880},

  # Log every effect instead of performing it. Ships TRUE: the first thing this
  # daemon does on the real broker should be to tell you what it would have
  # done. Three of the rules it replaces have never fired in production.
  dry_run: true,

  # How long after boot -- and after every broker reconnect -- merlin learns
  # the state of the house without acting on it. Retained messages replay in a
  # burst on connect and are indistinguishable from the whole house changing at
  # once; without this the intruder latch fires and the lamps toggle every time
  # the wifi hiccups.
  settle_ms: 15_000,

  # Facts that survive a restart.
  #
  # Device state is deliberately absent. The broker already re-announces every
  # plug and door via retained messages on connect, and persisting them here
  # would mean two sources of truth for the same value, with merlin's copy
  # being the stale one.
  #
  # What is here is what nothing else can tell us again: where people and
  # vehicles were. These carry stale_after, so a restart that takes two hours
  # restores them already stale and they read :unknown -- which is the honest
  # answer and the entire reason the snapshot records ages rather than values
  # alone.
  #
  # Machine state and data slots are NOT listed: a machine declares
  # `persist: true` beside its own states, and contributes [:rule, <id>] itself.
  persist: [
    [:person],
    [:vehicle]
  ],

  # Zones each carry their own size, and leaving requires travelling further
  # than arriving did. The Python had ONE 0.25-mile constant serving as every
  # geofence radius and as the phone-to-vehicle distance, with no hysteresis at
  # all -- which was survivable only because the away path was dead code.
  #
  # Coordinates are approximate placeholders. Replace with the real ones before
  # cutover; nothing here is a secret, but nothing here is right either.
  # Taken from the Python's [[hooks.regions]] on merlin itself, not invented.
  # The values that were here before were plausible-looking coordinates in the
  # wrong STATE, which would have left every presence rule permanently
  # :unknown -- a house that looked quiet rather than broken.
  zones: [
    %{
      id: :home,
      center: {51.4779, -0.0015},
      radius: {0.25, :mi},
      hysteresis: 1.25
    },
    %{id: :workshop, center: {51.5537, -0.0708}, radius: {0.25, :mi}}
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
      set_topic: "z2m/living_room_lamps/set",
      encode: {:json_state, %{on: "ON", off: "OFF"}}
    },

    # A group with members and no set_topic: a named SET of facts, not a
    # command target. Nothing is ever published to "the exterior doors".
    #
    # This is what makes "only exterior doors alarm" data. The doors all
    # arrive from one wildcard source and have identically shaped paths, so
    # `{:changes_under, [:door]}` cannot tell a balcony door from a bedroom
    # door -- the distinction is about the house, not about the path, and it
    # belongs here rather than in a prefix.
    #
    # Adding a door to the house means adding a line here, and the rule that
    # watches it follows automatically: the group's members are the rule's
    # subscription.
    %{
      id: :exterior_doors,
      members: [
        [:door, "garage", :contact],
        [:door, "front", :contact],
        [:door, "back", :contact]
      ]
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
      topic: "z2m/home/living_room/plug/lamp_1",
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
      topic: "z2m/home/living_room/plug/lamp_2",
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
      topic: "z2m/home/living_room/switch/lamps/action",
      decode: :raw,
      events: [
        %{
          path: [:button, :living_room, :pressed],
          codec: {:enum, %{"single" => :single, "double" => :double}}
        }
      ]
    },

    # --- 3D printer (klipper_monitor.py) -----------------------------------
    # The Python conflated two different things on one state key: power
    # COMMANDS (ON/OFF/REBOOT) and print LIFECYCLE (printing/complete). One was
    # a mailbox, the other a state, and two hooks raced to reset the mailbox.
    # They are an event and a fact here, and nothing resets anything.
    %{
      id: :printer_power_request,
      topic: "bubbles/anycubic_kobra_neo/power",
      decode: :raw,
      events: [
        %{
          path: [:printer, :kobra_neo, :power_request],
          codec: {:enum, %{"ON" => :on, "OFF" => :off, "REBOOT" => :reboot}}
        }
      ]
    },
    %{
      id: :printer_job,
      topic: "moonraker/status/print_stats",
      decode: :json,
      facts: [
        %{
          path: [:printer, :kobra_neo, :job],
          # Moonraker reports state at either depth depending on the message;
          # klipper_monitor.py handled both with an `or`.
          from: [["state"], ["print_stats", "state"]],
          codec:
            {:enum,
             %{
               "printing" => :printing,
               "complete" => :complete,
               "cancelled" => :cancelled,
               "error" => :error,
               "standby" => :standby
             }}
        }
      ]
    },

    # --- office A/C (office_aircond.py) ------------------------------------
    %{
      id: :office_ac,
      topic: "z2m/home/office/plug/climate",
      decode: :json,
      facts: [
        %{
          path: [:climate, :office, :power],
          from: [["state"]],
          codec: {:enum, %{"ON" => :on, "OFF" => :off}}
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
        %{path: [:person, :owner, :lat], from: [["gps_latitude"]]},
        %{path: [:person, :owner, :lon], from: [["gps_longitude"]]},
        %{path: [:person, :owner, :accuracy_m], from: [["gps_accuracy"]]},
        # `batt_level`, which is what the device sends. `battery_level` was a
        # transcription and never matched anything.
        %{path: [:person, :owner, :battery_pct], from: [["batt_level"]]},
        %{path: [:person, :owner, :altitude_m], from: [["gps_altitude"]]},
        %{path: [:person, :owner, :speed], from: [["gps_speed"]]}
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
      topic: "z2m/home/+room/sensor/contact",
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
    # --- the vehicle tracker (hapn_tracker.py) ------------------------------
    # All ten fields, not the three the Python actually used. It captured
    # speed, heading, mileage, battery, accuracy, send time and street address
    # and then read none of them -- which is why the "better vehicle rule" you
    # chose at planning was not expressible: the data was there and discarded.
    #
    # Credentials are secret references. merlin.exs is a document about the
    # house; merlin.secrets.exs is the thing nobody else can read.
    %{
      id: :hapn,
      kind: :http_poll,
      every: {2, :minute},
      auth: [
        url: {:secret, :hapn_auth_endpoint},
        client_id: {:secret, :hapn_client_id},
        client_secret: {:secret, :hapn_client_secret}
      ],
      request: [url: {:secret, :hapn_device_endpoint}, headers: [{"accept", "application/json"}]],
      root: "result",
      # A tracker silent for twenty minutes is not evidence of the car being
      # anywhere. The Python froze the last position forever.
      stale_after_ms: 1_200_000,
      # EVERY numeric field arrives as a JSON string -- "51.47765", "1", "0".
      # Without a codec they land as binaries, and the geofence requires
      # numbers, so vehicle.car.zone stayed :unknown for ever and every
      # vehicle rule was inert. Found on the first live poll; a dry-run soak
      # would have shown this as a car that was simply never anywhere.
      #
      # There is no `batteryPercentage` in this API's response. That field
      # came from hapn_tracker.py rather than from the endpoint, so "all ten
      # fields" was nine fields and an aspiration. The real response also
      # carries cellId, imei, reportType, created and hoursOfOperation, none
      # of which anything here needs yet.
      facts: [
        %{path: [:vehicle, :car, :lat], from: ["latitude"], codec: :float},
        %{path: [:vehicle, :car, :lon], from: ["longitude"], codec: :float},
        %{path: [:vehicle, :car, :accuracy_m], from: ["gpsAccuracy"], codec: :float},
        %{path: [:vehicle, :car, :heading_deg], from: ["azimuth"], codec: :float},
        %{path: [:vehicle, :car, :odometer_mi], from: ["odoMileage"], codec: :float},
        %{path: [:vehicle, :car, :speed_mph], from: ["speed"], codec: :float},
        # Timestamps and prose stay as they arrive: "20260827072921" is not a
        # number in any useful sense, and parsing it here would invent a
        # timezone the API does not state.
        %{path: [:vehicle, :car, :fix_at], from: ["gpsUTCTime"]},
        %{path: [:vehicle, :car, :reported_at], from: ["sendTime"]},
        %{path: [:vehicle, :car, :address], from: ["address"]}
      ]
    },

    # --- weather (weather.py) -----------------------------------------------
    # NOT CONFIGURED, and deliberately absent rather than present-and-broken.
    #
    # The Python has `runners/weather.py` in the tree and no weather entry in
    # config.toml at all -- no endpoint, no key, no runner block. It has never
    # run. Porting it because the file existed was reading the code and not the
    # configuration, which is the same mistake that put this house's zones in
    # the wrong state.
    #
    # Shipping the poller anyway would mean referencing secrets that do not
    # exist, and preflight would rightly refuse to start the daemon. To enable
    # it: add weather_endpoint and weather_api_key to merlin.secrets.exs and
    # restore an :http_poll entry here. Merlin.Source.HttpPoll needs no changes
    # and tier 5 already covers it.

    # --- the geofences ------------------------------------------------------
    # Modules, because this is geometry. Zone definitions are data, because
    # they are facts about your house.
    %{
      id: :owner_presence,
      kind: :geofence,
      lat: [:person, :owner, :lat],
      lon: [:person, :owner, :lon],
      accuracy: [:person, :owner, :accuracy_m],
      max_accuracy_m: 100,
      # How fast this person could plausibly travel. Used to decide how long a
      # fix remains an ANSWER: once somewhere else has been reachable for
      # longer than the fix is old, the zone becomes :unknown rather than
      # standing indefinitely.
      #
      # A flat stale_after cannot express this. Thirty minutes is neither
      # generous nor safe and says nothing about geography; "could he be home
      # by now" is the question the rules actually ask, and distance divided
      # by speed answers it.
      #
      # Generous on purpose: this is a bound on the possible, not a typical
      # journey. Being too fast only shortens how long merlin will claim to
      # know where someone is, which is the safe direction.
      max_speed: {120, :kph},
      out: [:person, :owner, :zone],
      out_position: [:person, :owner, :position],
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
      # Faster than the phone: a car on a motorway.
      max_speed: {160, :kph},
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
    # Bug 7. office_aircond.py restored the A/C on the REQUEST value, so a
    # REBOOT un-masked immediately and the A/C came back at t=0 rather than
    # after the ten-second cycle. Shedding on "busy" instead, where busy
    # includes the dwell, makes the window correct by construction.
    %{
      id: :printer_busy,
      kind: :expr,
      out: [:printer, :kobra_neo, :busy?],
      compute: "printer.kobra_neo.job == :printing or rule.printer_power.state != :idle"
    },
    %{
      id: :vehicle_with_phone,
      kind: :expr,
      out: [:vehicle, :car, :with_phone?],
      compute: "within?(vehicle.car.position, person.owner.position, 402.34)"
    },
    %{
      id: :vehicle_unaccounted,
      kind: :expr,
      out: [:vehicle, :car, :unaccounted?],
      # `== :away`, not `unknown?`. A tracker that has gone dark is not
      # evidence of theft, it is evidence of a dead tracker -- and alerting on
      # it is the false-positive that trains you to ignore the alert. This
      # fires only when the car is visibly somewhere unnamed and not with the
      # phone.
      #
      # The cost, stated: a thief who disables the tracker produces :unknown
      # and no alert. That is the same trade every rule here makes -- merlin
      # does not act on what it cannot see -- and it is why this is pointed at
      # :log until you have watched it.
      compute: "vehicle.car.zone == :away and vehicle.car.with_phone? == false",
      # Your decision at planning. alerts.py fired on the first false-edge of a
      # flag derived from one GPS reading, so a single bounced fix at a zone
      # edge was an alert. Two minutes of continuous truth, or nothing.
      hold: {:true_for, {2, :minute}}
    },
    %{
      id: :vehicle_away_while_home,
      kind: :expr,
      out: [:vehicle, :car, :away_while_home?],
      # No `defined?` guard, deliberately, and the mutation check is what
      # settled it.
      #
      # `defined?(zone) and zone != :home` and plain `zone != :home` behave
      # identically for a RULE, because both are non-truthy when the zone is
      # unknown and a guard fires only on literal true. But this is a derived
      # FACT, and the values differ: with the guard it reads `false`, without
      # it `:unknown`.
      #
      # `false` asserts "we checked, the car is not away while you are home".
      # `:unknown` says "the tracker is dark and we cannot tell". The second is
      # true and the first is not, and the whole point of the tri-state is to
      # stop the daemon claiming knowledge it does not have. Propagation
      # already prevents the alert from firing.
      compute: "person.owner.zone == :home and vehicle.car.zone != :home",
      hold: {:true_for, {2, :minute}}
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
      on: [{:leaves, [:person, :owner, :zone], :home}],
      # Only on a real departure. Leaving :home for :unknown means we lost the
      # phone, not that you went out.
      when: "defined?(person.owner.zone)",
      do: [{:set_group, :living_room_lamps, :off}]
    },

    # Your decision: on ARRIVAL, and only after dark. `enters` is an edge, so
    # this cannot fire merely because you are already home.
    %{
      id: :lamps_on_when_arriving_after_dark,
      desc: "Turn the living room lamps on when I arrive home after dark.",
      on: [{:enters, [:person, :owner, :zone], :home}],
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
      # :log, not :discord. This path has no operational history. After a
      # fortnight of watching the log, change one word.
      do: [{:notify, :log, "vehicle unaccounted for: not in a known zone and not with the phone"}]
    },
    %{
      id: :vehicle_away_while_home_alert,
      desc: "Log when I am home and the car is not.",
      on: [{:enters, [:vehicle, :car, :away_while_home?], true}],
      do: [{:notify, :log, "vehicle is away while I am home"}]
    },

    # --- the printer power sequence (3dprinter_kobra_neo.py) ---------------
    # REBOOT is OFF, wait ten seconds, ON. In the Python that wait was
    # `await asyncio.sleep(10)` inside the hook: it blocked that hook's task
    # for ten seconds and nothing could cancel it. Here it is a state timeout,
    # which cancels itself if anything moves the machine out of :dwell.
    %{
      id: :printer_power,
      desc: "3D printer power. ON and OFF pass through; REBOOT power-cycles with a 10s dwell.",
      machine: %{
        initial: :idle,
        states: %{
          idle: [
            %{
              on: {:receives, [:printer, :kobra_neo, :power_request]},
              when: "trigger.value == :on",
              do: [{:publish, "z2m/home/office/plug/3d_printer/set", ~s({"state":"ON"})}]
            },
            %{
              on: {:receives, [:printer, :kobra_neo, :power_request]},
              when: "trigger.value == :off",
              do: [{:publish, "z2m/home/office/plug/3d_printer/set", ~s({"state":"OFF"})}]
            },
            %{
              on: {:receives, [:printer, :kobra_neo, :power_request]},
              when: "trigger.value == :reboot",
              do: [
                {:publish, "z2m/home/office/plug/3d_printer/set", ~s({"state":"OFF"})},
                {:log, :info, "printer reboot: power cut, 10s dwell"}
              ],
              goto: :dwell
            }
          ],
          dwell: [
            %{
              on: {:after, {10, :second}},
              do: [{:publish, "z2m/home/office/plug/3d_printer/set", ~s({"state":"ON"})}],
              goto: :idle
            },
            # A request arriving mid-cycle is deferred, not dropped. One
            # keyword instead of a hand-rolled pending queue.
            %{on: {:receives, [:printer, :kobra_neo, :power_request]}, postpone: true}
          ]
        }
      }
    },

    # --- the A/C load shed (office_aircond.py) -----------------------------
    # The subtlest logic in the Python, and the reason machines exist here.
    # While shedding, an OFF report from the plug is our own command echoing
    # back and must NOT overwrite the remembered desire -- otherwise the
    # restore has nothing to restore to.
    #
    # In the Python the mask was `self.printer_active`, an instance variable
    # no rule could read, no dashboard could show and no restart preserved.
    # Here it is the state name, published as rule.office_load_shed.state.
    #
    # Bug 7 is fixed by shedding on the printer being BUSY rather than on the
    # request: printer.kobra_neo.busy? stays true through the reboot dwell, so
    # the A/C no longer comes back on at the start of a power cycle.
    %{
      id: :office_load_shed,
      desc: "The office A/C yields to the 3D printer, and my desired setting is restored after.",
      machine: %{
        initial: :idle,
        data: %{desired: :off},
        # `desired` is the only record of what I actually want the A/C set to.
        # Losing it on restart means the next restore turns the A/C to whatever
        # the plug happened to be reporting.
        persist: true,
        states: %{
          idle: [
            # While idle, what the plug reports IS what I want.
            %{
              on: {:changes, [:climate, :office, :power]},
              set: %{desired: {:expr, "climate.office.power"}}
            },
            %{
              on: {:enters, [:printer, :kobra_neo, :busy?], true},
              set: %{desired: {:expr, "climate.office.power"}},
              do: [
                {:publish, "z2m/home/office/plug/climate/set", ~s({"state":"OFF"})},
                {:log, :info, "shedding office A/C for the printer"}
              ],
              goto: :shedding
            }
          ],
          shedding: [
            # The mask: an OFF report while shedding is our own command coming
            # back, and must not be recorded as the desired state.
            #
            # HONESTLY: this clause is currently redundant, and a mutation that
            # deletes it survives the whole battery. Nothing else in :shedding
            # matches a climate change with value :off -- the next clause is
            # guarded on :on -- so the report already falls through to
            # ignore-by-default and the desire is preserved either way.
            #
            # It is kept as defensive documentation, not as behaviour. The
            # Python NEEDED an explicit mask because its fallthrough was
            # `else: state.set(...)`, which would have recorded the echo; here
            # the fallthrough is "do nothing". Keeping the clause means that if
            # anyone later adds a general climate-change clause to this state,
            # this one shadows it for the :off case and the mask survives the
            # edit. Remove it only if you also convince yourself of that.
            #
            # The PROPERTY -- the desire survives the plug's echo -- is what
            # tier 6 asserts, by echoing the plug state mid-cycle and requiring
            # the restore to still happen.
            %{on: {:changes, [:climate, :office, :power]}, when: "climate.office.power == :off"},

            # An ON report while shedding is a deliberate human override.
            # Honour it and stop shedding. The Python swallowed this.
            %{
              on: {:changes, [:climate, :office, :power]},
              when: "climate.office.power == :on",
              set: %{desired: :on},
              do: [{:log, :info, "office A/C overridden by hand during a print; load shed abandoned"}],
              goto: :overridden
            },

            %{
              on: {:leaves, [:printer, :kobra_neo, :busy?], true},
              when: "local.desired == :on",
              do: [
                {:publish, "z2m/home/office/plug/climate/set", ~s({"state":"ON"})},
                {:log, :info, "printer finished; restoring office A/C"}
              ],
              goto: :idle
            },
            %{on: {:leaves, [:printer, :kobra_neo, :busy?], true}, goto: :idle},

            # Never shed forever if the printer stops reporting altogether.
            %{
              on: {:after, {12, :hour}},
              do: [{:log, :warning, "load-shed watchdog expired; leaving the A/C alone"}],
              goto: :idle
            }
          ],
          overridden: [
            %{
              on: {:changes, [:climate, :office, :power]},
              set: %{desired: {:expr, "climate.office.power"}}
            },
            %{on: {:leaves, [:printer, :kobra_neo, :busy?], true}, goto: :idle}
          ]
        }
      }
    },

    # --- the intruder latch (alerts.py) ------------------------------------
    # One alert per absence, re-armed on return. In the Python this was
    # `self.presence_alert_fired`, a boolean that vanished on restart -- so a
    # daemon restart mid-absence would alert again for the same intrusion.
    # A latch is a state, not a boolean.
    #
    # Pointed at :log, not a notifier. This path has NEVER executed: it was
    # gated on `USR_LOC_HOME_FLAG is False`, which bug 2 made unreachable.
    # Watch it for a fortnight before it is allowed to wake you.
    %{
      id: :intruder_latch,
      desc: "If a door moves while I am away, log once. Re-arm when I get home.",
      machine: %{
        initial: :armed,
        # A latch that re-arms on restart is not a latch. alerts.py held this
        # in an instance variable and every restart silently forgave whatever
        # had already happened.
        persist: true,
        states: %{
          armed: [
            %{
              # The exterior doors only, by name. Under `{:changes_under,
              # [:door]}` this fired on the bedroom door and the office door
              # -- so walking around the house while the phone had no fix was
              # indistinguishable from someone coming in through a window.
              on: {:changes_in, :exterior_doors},
              # Any time we can SEE he is not home -- at the workshop, at the
              # supermarket, anywhere with a usable fix outside the house.
              #
              # The :unknown exclusion is what stops a lost phone from firing
              # an intruder alert, and it is the whole reason :away had to
              # exist separately: before it, "somewhere unnamed" and "no fix"
              # were the same value, so excluding one excluded both and this
              # rule could only ever fire at the workshop.
              # `defined?`, not `!= :unknown`. Every operator propagates
              # :unknown, so comparing against the literal makes the whole
              # guard permanently :unknown and the rule never fires. The
              # compiler refuses that spelling now; this is the one that works.
              when: "defined?(person.owner.zone) and person.owner.zone != :home",
              # Also :log. alerts.py gated this on a flag bug 2 made
              # unreachable, so it has never fired in production either.
              # Names the door. `trigger.room` is the topic wildcard the fact
              # was written from, which is the only place the room survives:
              # it is a path segment, and a value is all a rule could read
              # until changes carried their captures.
              do: [
                {:notify, :log,
                 {:expr,
                  "\"unexpected activity at home while I am away: \" + " <>
                    "to_s(trigger.room, \"an unnamed door\")"}}
              ],
              goto: :fired
            }
          ],
          fired: [
            %{
              on: {:enters, [:person, :owner, :zone], :home},
              do: [{:log, :info, "intruder latch re-armed"}],
              goto: :armed
            }
          ]
        }
      }
    },

    # --- doors -------------------------------------------------------------
    # The presence edge home_doors.py faked with a time.time() timestamp. It is
    # an event now, and it names the room -- which the Python's generic
    # "Unexpected presence detected at home!" alert could not.
    %{
      id: :door_presence,
      desc: "A door changing state is a presence event, naming the room.",
      # Every door, interior included: this one only observes.
      on: [{:changes_under, [:door]}],
      do: [
        {:log, :info,
         {:expr, "to_s(trigger.room, \"unnamed door\") + \" \" + to_s(trigger.value)"}}
      ]
    }
  ]
}
