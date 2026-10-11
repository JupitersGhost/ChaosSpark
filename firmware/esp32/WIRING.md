# GPIO35 modular passive-pickup input

GPIO34 keeps its present pickup and wiring. This addition uses GPIO35 only.
The firmware accepts the raw ADC voltage; it neither detects a plug nor
identifies a pickup. Use a two-pin connector marked HOT and RETURN on the
pickup side of a permanent input circuit. The same connector can take the
two-conductor ESP humbucker or the Jazz single coil, without reflashing.
Identify the actual leads; do not infer colors from a different manufacturer.
For a four-conductor humbucker, retain its correct series link or use the Jazz
pickup until the wiring is identified.

## Empty socket versus floating ADC

| Physical arrangement | What happens |
|---|---|
| GPIO35 has no external connection at all | The ADC floats and may show changing readings. Firmware keeps measuring; pickup presence remains unknown. |
| GPIO35 is connected to the bias circuit below; pickup socket empty | The ADC rests near its bias voltage, with whatever circuit/ADC noise remains. It is not floating. |
| Passive pickup connected through the circuit | Its AC signal rides on the bias voltage. Firmware measures the same generic channel. |

GPIO35 has no internal pull resistors. Firmware cannot switch a permanent
external bias resistor out of circuit. True automatic switching would need
extra hardware, such as a separate jack-detect contact and an analog switch;
none is needed for this basic modular port.

## Prototype input circuit

This is a passive, attenuating prototype for loose passive magnetic pickups,
not a universal sensor port or a measured, qualified entropy source. It has
not been assembled or bench-tested here. A humbucker can produce too little
ambient signal for this passive circuit; its acceptance is determined by the
measurements, not by pickup type.

Use these parts:

| Part | Quantity | Purpose |
|---|---:|---|
| Two-pin connector | 1 | Pickup HOT / RETURN |
| 1 µF nonpolar film capacitor, rated at least 16 V | 1 | Block DC between the pickup and biased ADC node |
| 10 kΩ resistor | 2 | Series current limiting and lower bias resistor |
| 18 kΩ resistor | 1 | Upper bias resistor |
| 100 nF ceramic capacitor | 1 | Local ADC charge reservoir and low-pass filtering |
| Small-signal Schottky diodes, such as BAT54 | 2 | External steering clamps; verify the purchased package pinout |

Call the junction attached to GPIO35 **A**. Connect:

| From | Through | To |
|---|---|---|
| Pickup HOT | 1 µF capacitor, then one 10 kΩ series resistor | A / GPIO35 |
| Pickup RETURN | Wire | ESP32 GND |
| ESP32 3V3 | 18 kΩ resistor | A |
| A | Remaining 10 kΩ resistor | ESP32 GND |
| A | 100 nF capacitor | ESP32 GND |
| ESP32 GND | Lower clamp diode: anode at GND, cathode at A | A |
| A | Upper clamp diode: anode at A, cathode at 3V3 | ESP32 3V3 |

The divider sets approximately 3.3 × 10 / (18 + 10) = **1.18 V** at A when
the socket is empty. Place the bias resistors, capacitor and clamp diodes
close to the ESP32; keep the ground return short. Use the board's **3V3** pin,
not VIN/5V. If the pickup has a separate metal shield, connect it to GND,
not A. With a combined shield/return lead, that lead goes to GND.

This network loads and attenuates the pickup, which is acceptable for this
first environmental measurement but does change its response. The 100 nF
capacitor filters variation; it does not improve or certify entropy. Clamp
voltages depend on diode current and temperature. The diodes limit excursions
but do not guarantee an arbitrary signal is safe or inside the ADC's accurate
range; they are not a certified ESD/overvoltage interface.

Build with power removed. Initially leave A disconnected from GPIO35, power
the board, and check the empty-socket DC bias with a meter. It should be near
1.18 V. Check pickup-driven excursions with an oscilloscope if available;
a meter and the firmware's endpoint counters cannot reveal transient extremes.
Then power off before attaching A to GPIO35 or changing pickup leads.
Keep normal ADC voltage within the board's electrical limits and aim to stay
roughly within 0.15–2.45 V for the documented calibrated range at this attenuation.
Do not plug amplifier/speaker outputs, piezo sensors or powered/5 V modules
into this passive-pickup connector. Those need their own input design.

## First capture

The firmware can be tested with GPIO35 entirely disconnected before assembling
the input circuit. Keep GPIO34's physical setup unchanged and record whether
GPIO35 is bare/unconnected, biased with an empty socket, or connected to a named
pickup. These are different electrical experiments. A startup or health-test
failure on GPIO35 does not stop the other sources.

After a swap, power up, allow startup checks to run, and record a five-minute
capture. Compare GPIO35 rail occupancy, variation and autocorrelation; also
inspect GPIO34/GPIO35 correlation, sampling rate and heap. An empty, noisy
input can pass basic health checks. A quiet connected pickup can fail them.
Neither result identifies whether a pickup is attached.

## Reference

[Espressif ESP32 datasheet](https://www.espressif.com/sites/default/files/documentation/esp32_datasheet_en.pdf)
documents GPIO35 as ADC1 channel 7, the lack of internal pull resistors on
GPIO34–39, and the calibrated ADC range and electrical limits. The prototype
circuit above is our design proposal, not an Espressif reference circuit.
