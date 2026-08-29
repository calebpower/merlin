# Kept as EVIDENCE, not as an oracle.
#
# This is the tier 9 run that found the geofence pairing components across
# two different arrivals for the second time. Replaying it does NOT
# reliably reproduce the violation: the seed fixes the sequence of device
# actions, not the scheduler, and the crossing is only visible when the
# geofence is scheduled between the coordinate writes and the accuracy
# write. That is why the regression test for it is tier 1 and pins the
# interleaving directly -- see
# test/tier1/geofence_test.exs, "two observations closer together than
# the window are not crossed".
#
# This file is here so the run that found it is not just a deleted log.

# A tier 9 trace that violated an invariant. Committable as a regression
# case: feed `actions` to the house in order and re-check the invariants.
#
# seed:   6339
# shrunk: no -- budget exhausted, not minimal
# found:  2026-08-29T06:24:13.545854Z
%{
  seed: 6339,
  shrunk?: false,
  violations: [:latch_stays_fired_until_home],
  actions: [
  {:printer_reboot},
  {:door, "garage", "ON"},
  {:door, "bedroom", "ON"},
  {:phone, :boundary, 30},
  {:duplicate},
  {:malformed, "z2m/home/garage/sensor/contact",
   "{\"state\":{\"nested\":\"object\"}}"},
  {:door, "front", "OFF"},
  {:door, "back", "ON"},
  {:climate, "OFF"},
  {:door, "garage", "ON"},
  {:door, "garage", "OFF"},
  {:climate, "OFF"},
  {:button, "double"},
  {:door, "garage", "OFF"},
  {:reconnect},
  {:door, "garage", "ON"},
  {:button, "double"},
  {:door, "back", "ON"},
  {:phone, :away, 120},
  {:climate, "OFF"},
  {:door, "back", "ON"},
  {:print_job, "standby"},
  {:door, "garage", "ON"},
  {:climate, "OFF"},
  {:print_job, "complete"},
  {:door, "back", "OFF"},
  {:door, "back", "OFF"},
  {:phone, :away, 120},
  {:print_job, "standby"},
  {:climate, "OFF"},
  {:phone, :boundary, 30},
  {:door, "front", "OFF"},
  {:malformed, "z2m/home/office/plug/climate", "[1,2,3]"},
  {:climate, "OFF"},
  {:climate, "OFF"},
  {:door, "back", "OFF"},
  {:button, "double"},
  {:phone, :boundary, 30},
  {:climate, "OFF"},
  {:phone, :home, 120},
  {:print_job, "complete"},
  {:button, "double"},
  {:climate, "ON"},
  {:phone, :boundary, 30},
  {:climate, "OFF"},
  {:button, "single"},
  {:button, "single"},
  {:phone, :home, 5}
]
}
