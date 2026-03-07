# ESP32 Support

NullClaw treats ESP32 as a **managed peripheral**: the NullClaw process runs on a host machine
(macOS, Linux, Windows, or Docker) and communicates with the ESP32 over USB serial. The agent can
read GPIO pins, read ADC channels, write GPIO pins, and flash new firmware — all from a natural
language conversation or automated tool call.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Host machine (macOS / Linux / Docker)              │
│                                                     │
│  nullclaw agent  ←→  LLM (OpenRouter / Anthropic)  │
│       │                                             │
│  Esp32Peripheral                                    │
│  (src/peripherals.zig)                              │
│       │  newline-delimited JSON over USB serial     │
└───────┼─────────────────────────────────────────────┘
        │  USB (CP2102 / CH340 bridge)
┌───────┼─────────────────────────────────────────────┐
│  ESP32 firmware (FreeRTOS / ESP-IDF)                │
│  – UART JSON command handler                        │
│  – GPIO read / write                                │
│  – ADC read (GPIO32-GPIO39)                         │
└─────────────────────────────────────────────────────┘
```

NullClaw itself does **not** run on the ESP32. The ESP32 is a peripheral node.

---

## Host Requirements

| Requirement | Notes |
|---|---|
| NullClaw (host) | Built normally with `zig build -Doptimize=ReleaseSmall` |
| Python ≥ 3.7 | Required by esptool.py |
| esptool.py | `pip install esptool` — used for firmware flash |
| USB serial driver | CP210x (`cp210x` kernel module) or CH340 (`ch34x`) |
| Serial port access | User must be in the `dialout` group on Linux |

Install esptool.py:

```bash
pip install esptool
esptool.py version   # should print version info
```

Grant serial port access on Linux:

```bash
sudo usermod -aG dialout $USER
# log out and back in, then verify:
ls -la /dev/ttyUSB0
```

---

## Configuration

Add a `peripherals` block to `~/.nullclaw/config.json`:

```json
{
  "peripherals": {
    "enabled": true,
    "boards": [
      {
        "board": "esp32",
        "transport": "serial",
        "path": "/dev/ttyUSB0",
        "baud": 115200
      }
    ]
  }
}
```

| Field | Default | Notes |
|---|---|---|
| `board` | — | Must be `"esp32"` |
| `transport` | `"serial"` | Always `"serial"` for ESP32 |
| `path` | — | Serial port: `/dev/ttyUSB0` (Linux), `/dev/cu.usbserial-*` (macOS), `COM3` (Windows) |
| `baud` | `115200` | Standard ESP32 baud rate; most firmware uses 115200 |

macOS port path example: `/dev/cu.usbserial-0001` or `/dev/cu.SLAB_USBtoUART`.

---

## GPIO Pin Map

| Pin range | Type | Read | Write | Notes |
|---|---|---|---|---|
| GPIO0 – GPIO31 | Digital I/O | ✅ `gpio_read` | ✅ `gpio_write` | Standard bidirectional pins |
| GPIO32 – GPIO39 | ADC1 input-only | ✅ `adc_read` | ❌ `UnsupportedOperation` | Hardware-limited to input on ESP32 |
| > GPIO39 | — | ❌ `InvalidAddress` | ❌ `InvalidAddress` | Out of range |

GPIO2 is the built-in LED on most ESP32 DevKit boards.

---

## Flashing Firmware

`Esp32Peripheral.flashFirmware(path)` runs:

```bash
esptool.py --port /dev/ttyUSB0 --baud 115200 write_flash 0x0 firmware.bin
```

This flashes a raw binary image starting at address `0x0`. For a full ESP-IDF partition image
(bootloader + partition table + app), use the standard `idf.py flash` workflow directly, or supply
a merged binary.

Flash from the agent:

```
nullclaw agent -m "Flash firmware.bin to the ESP32 on /dev/ttyUSB0"
```

---

## Serial JSON Protocol (Firmware Side)

The ESP32 firmware must implement a newline-delimited JSON command handler on UART0 (the USB
serial port). NullClaw sends one command per line and reads back one response per line.

### Command format

```json
{"id":"1","cmd":"gpio_read","args":{"pin":2}}
{"id":"2","cmd":"gpio_write","args":{"pin":2,"value":1}}
{"id":"3","cmd":"adc_read","args":{"pin":34}}
```

### Response format

```json
{"id":"1","ok":true,"result":"1"}
{"id":"2","ok":true}
{"id":"3","ok":true,"result":"127"}
```

`result` for `gpio_read`: `"0"` (LOW) or `"1"` (HIGH).  
`result` for `adc_read`: `"0"`–`"255"` (8-bit scaled from 12-bit ADC reading).  
On error: `{"id":"N","ok":false,"error":"message"}`.

### Minimal Arduino / ESP-IDF sketch (C)

```c
#include <stdio.h>
#include "driver/gpio.h"
#include "driver/adc.h"
#include "esp_log.h"

void app_main(void) {
    char line[256];
    while (1) {
        if (fgets(line, sizeof(line), stdin) == NULL) continue;

        unsigned int msg_id = 0;
        char cmd[32] = {0};
        int pin = -1, value = -1;

        // Minimal sscanf-based parser — replace with cJSON for production use.
        sscanf(line, "{\"id\":\"%u\",\"cmd\":\"%31[^\"]\",\"args\":{\"pin\":%d", &msg_id, cmd, &pin);
        sscanf(line, "%*[^v]value\":%d", &value);

        if (strcmp(cmd, "gpio_read") == 0 && pin >= 0) {
            gpio_set_direction(pin, GPIO_MODE_INPUT);
            int v = gpio_get_level(pin);
            printf("{\"id\":\"%u\",\"ok\":true,\"result\":\"%d\"}\n", msg_id, v);

        } else if (strcmp(cmd, "gpio_write") == 0 && pin >= 0 && value >= 0) {
            gpio_set_direction(pin, GPIO_MODE_OUTPUT);
            gpio_set_level(pin, value);
            printf("{\"id\":\"%u\",\"ok\":true}\n", msg_id);

        } else if (strcmp(cmd, "adc_read") == 0 && pin >= 0) {
            // ADC1: GPIO32-GPIO39. Map pin to ADC1 channel.
            adc1_channel_t ch = (adc1_channel_t)(pin - 32);
            adc1_config_width(ADC_WIDTH_BIT_12);
            adc1_config_channel_atten(ch, ADC_ATTEN_DB_11);
            int raw = adc1_get_raw(ch);          // 0–4095
            int scaled = (raw * 255) / 4095;     // scale to 0–255
            printf("{\"id\":\"%u\",\"ok\":true,\"result\":\"%d\"}\n", msg_id, scaled);

        } else {
            printf("{\"id\":\"%u\",\"ok\":false,\"error\":\"unknown command\"}\n", msg_id);
        }
        fflush(stdout);
    }
}
```

---

## Compilation Analysis: ESP32 vs Native

This section explains **how each side compiles** and **why they are fundamentally different**.

### NullClaw (host side)

NullClaw compiles with Zig for the host OS. Nothing changes for ESP32 support — the host build is
identical to a standard native build:

```bash
# Standard native build (x86_64 Linux)
zig build -Doptimize=ReleaseSmall

# Cross-compile for Linux ARM (e.g., Raspberry Pi running NullClaw)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

The `Esp32Peripheral` vtable code in `src/peripherals.zig` compiles into every host binary. It
calls `esptool.py` as a subprocess at runtime.

### ESP32 firmware (device side)

The ESP32 firmware is a **completely separate compilation**, using a completely different toolchain:

| Dimension | NullClaw (host) | ESP32 firmware |
|---|---|---|
| Build system | `zig build` | `idf.py build` (ESP-IDF CMake) |
| Compiler | Zig 0.15.2 (LLVM backend) | `xtensa-esp32-elf-gcc` (GCC 12) |
| Target triple | `x86_64-linux-musl` / `aarch64-linux-musl` / etc. | `xtensa-esp32-none-elf` |
| OS / runtime | Linux + musl libc | FreeRTOS (bare-metal) |
| Architecture | x86_64 or aarch64 (host CPU) | Xtensa LX6 dual-core 240 MHz |
| SRAM | Host RAM (GBs) | 520 KB total |
| Flash storage | Host filesystem | 4 MB SPI flash |
| Heap | `std.heap.GeneralPurposeAllocator` | FreeRTOS `pvPortMalloc` |
| Libc | musl (full POSIX) | ESP-IDF newlib (embedded subset) |
| Networking | Full TCP/IP stack (HTTP, TLS) | lwIP (optional Wi-Fi) |
| SQLite | Fully supported | Not supported (insufficient RAM) |
| Entry point | `main()` → CLI routing | `app_main()` → FreeRTOS task |

### Why NullClaw cannot run directly on ESP32

| Constraint | Detail |
|---|---|
| **RAM** | NullClaw needs ~1–5 MB peak RSS. ESP32 has 520 KB total SRAM. |
| **SQLite** | Requires `mmap`, `pwrite`, POSIX file I/O — unavailable on bare-metal. |
| **HTTP client** | `std.http.Client` requires TCP sockets — available via ESP-IDF Wi-Fi, but the rest of NullClaw cannot fit. |
| **Channels/providers** | TLS 1.3 + JSON parsing + LLM API HTTP calls exceeds the RAM budget. |
| **WASM target** | Even the minimal WASI build (~900 KB) needs a WASI runtime; no WASI runtime exists for FreeRTOS. |

The closest approach: run NullClaw on a host (including a Raspberry Pi), use the ESP32 as a GPIO
sensor/actuator peripheral via `Esp32Peripheral`.

---

## Feature Comparison: All Deployment Targets

| Feature | Native | Docker | WASM/WASI | Cloudflare Workers | ESP32 (peripheral) |
|---|---|---|---|---|---|
| **LLM providers** (OpenAI, Anthropic, etc.) | ✅ | ✅ | ❌ | ❌ (JS host calls) | ✅ (host side) |
| **SQLite memory backend** | ✅ | ✅ | ❌ | ❌ | ✅ (host side) |
| **Messaging channels** (Telegram, Discord, etc.) | ✅ | ✅ | ❌ | ❌ | ✅ (host side) |
| **HTTP gateway** | ✅ | ✅ | ❌ | ❌ | ✅ (host side) |
| **Shell / filesystem access** | ✅ | ✅ (mount) | ❌ | ❌ | ❌ (firmware only) |
| **Security sandboxes** (Landlock / Firejail / Docker) | ✅ | ✅ | ❌ | ❌ | N/A |
| **Long-running daemon** | ✅ | ❌ | ❌ | ❌ | N/A |
| **GPIO read / write** | ❌ | ❌ | ❌ | ❌ | ✅ (GPIO0-GPIO31) |
| **ADC read** | ❌ | ❌ | ❌ | ❌ | ✅ (GPIO32-GPIO39) |
| **Firmware flash** | ❌ | ❌ | ❌ | ❌ | ✅ (`esptool.py`) |
| **Arduino GPIO** | ❌ | ❌ | ❌ | ❌ | ✅ (via `ArduinoPeripheral`) |
| **STM32/Nucleo flash** | ❌ | ❌ | ❌ | ❌ | ✅ (via `NucleoFlash`) |
| **RPi native GPIO** | ❌ | ❌ | ❌ | ❌ | ✅ (via `RpiGpioPeripheral`) |
| **Hardware auto-discovery** | ✅ | ✅ | ❌ | ❌ | ✅ (host side) |
| **Offline operation** | ✅ (Ollama) | ✅ (Ollama) | ✅ (keyword only) | ❌ | ✅ (host side + Ollama) |
| **Binary size** | ~678 KB | ~678 KB | ~900 KB (WASI) | ~4 KB | N/A (firmware separate) |
| **Peak RSS** | ~1–5 MB | ~1–5 MB | ~2 MB | < 128 KB | N/A |

### ESP32 vs Arduino vs STM32/Nucleo vs RPi GPIO

These are all peripheral backends under the same `Peripheral` vtable interface:

| Dimension | ESP32 | Arduino Uno | STM32 Nucleo | Raspberry Pi |
|---|---|---|---|---|
| CPU | Xtensa LX6 dual-core | AVR ATmega328P | ARM Cortex-M4 | ARM Cortex-A (Linux) |
| Clock | 240 MHz | 16 MHz | 84–100 MHz | 1–2 GHz |
| SRAM | 520 KB | 2 KB | 128–512 KB | 256 MB – 8 GB |
| Flash | 4 MB | 32 KB | 512 KB | SD card (GB) |
| GPIO pins | GPIO0-GPIO39 (40) | D0-D13, A0-A5 | PA0-PC15 (varies) | 2-27 (26 usable) |
| ADC | 18 channels (12-bit) | 6 channels (10-bit) | 16 channels (12-bit) | None (hardware) |
| Flash tool | `esptool.py` | `arduino-cli` | `probe-rs` | Not flashable |
| GPIO access | Serial JSON | Serial JSON | `probe-rs read/write` | sysfs `/sys/class/gpio` |
| NullClaw transport | `serial` | `serial` | `probe` / `serial` | `native` |
| Built-in LED pin | GPIO2 | D13 | PA5 | None |
| Wi-Fi | ✅ built-in | ❌ | ❌ | ✅ (via OS) |

---

## Troubleshooting

### `DeviceNotFound` on init

`esptool.py` is not in PATH. Verify:

```bash
esptool.py version
```

If missing: `pip install esptool`. On some systems the command is `esptool` (no `.py`).

### `PermissionDenied` opening serial port

On Linux, add your user to the `dialout` group:

```bash
sudo usermod -aG dialout $USER
```

Log out and back in. Verify: `ls -la /dev/ttyUSB0` should show `crw-rw---- ... dialout`.

### `IoError` / `Timeout` on GPIO read

The ESP32 firmware is not running the JSON command handler on the expected serial port, or the
baud rate does not match. Check:

1. Firmware is flashed and running (serial monitor output visible).
2. `path` in config matches the actual device node (`/dev/ttyUSB0` vs `/dev/ttyUSB1`).
3. `baud` in config matches the firmware UART speed (typically `115200`).

### `UnsupportedOperation` when writing GPIO32-GPIO39

Pins GPIO32-GPIO39 are hardware-wired as ADC1 inputs on ESP32 and cannot be used as digital
outputs. Use GPIO0-GPIO31 for output. For sensing analog voltage, use `gpio_read` on GPIO32-GPIO39
(which internally dispatches `adc_read`).

### Flash fails with `esptool.py` error

- Hold the BOOT button while flashing if auto-reset is not wired.
- Reduce baud rate in config (try `57600` or `38400`).
- Ensure no other process (serial monitor) has the port open.
