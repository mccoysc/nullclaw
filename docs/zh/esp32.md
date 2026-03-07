# ESP32 使用指南

NullClaw 将 ESP32 作为**托管外设**使用：NullClaw 进程运行在宿主机（macOS、Linux、Windows 或 Docker），通过 USB 串口与 ESP32 通信。AI 助手可以读写 GPIO、读取 ADC、烧录固件，全部通过自然语言对话或自动化工具调用完成。

---

## 架构说明

```
┌─────────────────────────────────────────────────────┐
│  宿主机（macOS / Linux / Docker）                    │
│                                                     │
│  nullclaw agent  ←→  LLM（OpenRouter / Anthropic）  │
│       │                                             │
│  Esp32Peripheral                                    │
│  （src/peripherals.zig）                            │
│       │  USB 串口 — 换行分隔 JSON 协议               │
└───────┼─────────────────────────────────────────────┘
        │  USB（CP2102 / CH340 桥接芯片）
┌───────┼─────────────────────────────────────────────┐
│  ESP32 固件（FreeRTOS / ESP-IDF）                   │
│  – UART JSON 命令处理器                             │
│  – GPIO 读 / 写                                     │
│  – ADC 读（GPIO32-GPIO39）                          │
└─────────────────────────────────────────────────────┘
```

**NullClaw 本身不运行在 ESP32 上。** ESP32 是一个外设节点，宿主机上的 NullClaw 通过串口协议控制它。

---

## 1. 宿主机环境要求

| 要求 | 说明 |
|---|---|
| NullClaw（宿主机） | 正常构建：`zig build -Doptimize=ReleaseSmall` |
| Python ≥ 3.7 | esptool.py 的运行时依赖 |
| esptool.py | `pip install esptool`，ESP32 烧录工具 |
| USB 串口驱动 | CP210x（`cp210x` 内核模块）或 CH340（`ch34x`） |
| 串口权限（Linux） | 用户需加入 `dialout` 组 |

安装 esptool.py：

```bash
pip install esptool
esptool.py version   # 应输出版本信息
```

Linux 串口权限：

```bash
sudo usermod -aG dialout $USER
# 重新登录后验证：
ls -la /dev/ttyUSB0
```

macOS 无需额外权限，串口设备通常为 `/dev/cu.usbserial-*` 或 `/dev/cu.SLAB_USBtoUART`。

---

## 2. 配置 NullClaw

在 `~/.nullclaw/config.json` 中添加 `peripherals` 块：

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

| 字段 | 默认值 | 说明 |
|---|---|---|
| `board` | — | 固定填 `"esp32"` |
| `transport` | `"serial"` | ESP32 始终使用串口，无需修改 |
| `path` | — | 串口路径：Linux `/dev/ttyUSB0`、macOS `/dev/cu.SLAB_USBtoUART`、Windows `COM3` |
| `baud` | `115200` | 与固件 UART 速率保持一致，通常 115200 |

---

## 3. GPIO 引脚说明

| 引脚范围 | 类型 | 读 | 写 | 说明 |
|---|---|---|---|---|
| GPIO0 – GPIO31 | 数字 I/O | ✅ `gpio_read` | ✅ `gpio_write` | 标准双向 GPIO |
| GPIO32 – GPIO39 | ADC1 仅输入 | ✅ `adc_read` | ❌ `UnsupportedOperation` | 硬件限制，只能作模拟输入 |
| > GPIO39 | — | ❌ `InvalidAddress` | ❌ `InvalidAddress` | 超出范围 |

GPIO2 是大多数 ESP32 DevKit 开发板的板载 LED 引脚。

---

## 4. 烧录固件

`Esp32Peripheral.flashFirmware(path)` 内部执行：

```bash
esptool.py --port /dev/ttyUSB0 --baud 115200 write_flash 0x0 firmware.bin
```

从 NullClaw Agent 发起烧录：

```bash
nullclaw agent -m "把 firmware.bin 烧录到 /dev/ttyUSB0 上的 ESP32"
```

烧录完整 ESP-IDF 分区镜像（bootloader + 分区表 + 应用），建议直接使用 `idf.py flash`，或预先合并为单一 `.bin` 再交给 NullClaw 烧录。

---

## 5. ESP32 固件：串口 JSON 协议

ESP32 固件需在 UART0（USB 串口）上实现一个换行分隔 JSON 命令处理器。NullClaw 每次发送一行命令，读取一行响应。

### 命令格式

```json
{"id":"1","cmd":"gpio_read","args":{"pin":2}}
{"id":"2","cmd":"gpio_write","args":{"pin":2,"value":1}}
{"id":"3","cmd":"adc_read","args":{"pin":34}}
```

### 响应格式

```json
{"id":"1","ok":true,"result":"1"}
{"id":"2","ok":true}
{"id":"3","ok":true,"result":"127"}
```

- `gpio_read` 的 `result`：`"0"`（LOW）或 `"1"`（HIGH）。
- `adc_read` 的 `result`：`"0"`–`"255"`（12 位 ADC 值缩放为 8 位）。
- 出错时：`{"id":"N","ok":false,"error":"消息"}`。

### 最小 ESP-IDF 固件示例（C）

```c
#include <stdio.h>
#include "driver/gpio.h"
#include "driver/adc.h"

void app_main(void) {
    char line[256];
    while (1) {
        if (fgets(line, sizeof(line), stdin) == NULL) continue;

        unsigned int msg_id = 0;
        char cmd[32] = {0};
        int pin = -1, value = -1;

        // 简单 sscanf 解析；生产环境建议用 cJSON。
        sscanf(line, "{\"id\":\"%u\",\"cmd\":\"%31[^\"]\",\"args\":{\"pin\":%d",
               &msg_id, cmd, &pin);
        sscanf(line, "%*[^v]value\":%d", &value);

        if (strcmp(cmd, "gpio_read") == 0 && pin >= 0) {
            gpio_set_direction(pin, GPIO_MODE_INPUT);
            printf("{\"id\":\"%u\",\"ok\":true,\"result\":\"%d\"}\n",
                   msg_id, gpio_get_level(pin));

        } else if (strcmp(cmd, "gpio_write") == 0 && pin >= 0 && value >= 0) {
            gpio_set_direction(pin, GPIO_MODE_OUTPUT);
            gpio_set_level(pin, value);
            printf("{\"id\":\"%u\",\"ok\":true}\n", msg_id);

        } else if (strcmp(cmd, "adc_read") == 0 && pin >= 0) {
            adc1_channel_t ch = (adc1_channel_t)(pin - 32);
            adc1_config_width(ADC_WIDTH_BIT_12);
            adc1_config_channel_atten(ch, ADC_ATTEN_DB_11);
            int raw = adc1_get_raw(ch);           // 0–4095
            printf("{\"id\":\"%u\",\"ok\":true,\"result\":\"%d\"}\n",
                   msg_id, (raw * 255) / 4095);

        } else {
            printf("{\"id\":\"%u\",\"ok\":false,\"error\":\"unknown command\"}\n", msg_id);
        }
        fflush(stdout);
    }
}
```

---

## 6. 编译方式分析：与 Native 的区别

### NullClaw 宿主机侧（不变）

支持 ESP32 外设不需要修改 NullClaw 的编译方式，宿主机构建与普通 native 构建完全相同：

```bash
# 本机构建（宿主机 x86_64 Linux）
zig build -Doptimize=ReleaseSmall

# 交叉编译（宿主机运行在 Raspberry Pi 等 ARM 设备上）
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

`Esp32Peripheral` vtable 实现编译进每个宿主机二进制，运行时通过子进程调用 `esptool.py`。

### ESP32 固件侧（完全独立的编译链）

ESP32 固件是**完全独立的编译流程**，使用完全不同的工具链：

| 维度 | NullClaw 宿主机 | ESP32 固件 |
|---|---|---|
| 构建系统 | `zig build` | `idf.py build`（ESP-IDF CMake） |
| 编译器 | Zig 0.15.2（LLVM 后端） | `xtensa-esp32-elf-gcc`（GCC 12） |
| 目标三元组 | `x86_64-linux-musl` / `aarch64-linux-musl` 等 | `xtensa-esp32-none-elf` |
| 操作系统 | Linux + musl libc | FreeRTOS（裸机） |
| CPU 架构 | x86_64 或 aarch64（宿主机 CPU） | Xtensa LX6 双核 240 MHz |
| 内存 | 宿主机 RAM（GB 级） | 520 KB SRAM |
| 存储 | 宿主机文件系统 | 4 MB SPI Flash |
| 堆分配 | `std.heap.GeneralPurposeAllocator` | FreeRTOS `pvPortMalloc` |
| 标准库 | musl（完整 POSIX） | ESP-IDF newlib（嵌入式子集） |
| 网络 | 完整 TCP/IP + TLS | lwIP（可选，需 Wi-Fi） |
| SQLite | 完整支持 | 不支持（RAM 不足） |
| 入口函数 | `main()` → CLI 路由 | `app_main()` → FreeRTOS 任务 |

### 为什么 NullClaw 无法直接运行在 ESP32 上

| 约束 | 详情 |
|---|---|
| **RAM 不足** | NullClaw 峰值 RSS 约 1–5 MB，ESP32 仅有 520 KB SRAM |
| **SQLite** | 依赖 `mmap`、`pwrite`、POSIX 文件 I/O，裸机环境不可用 |
| **HTTP 客户端** | `std.http.Client` 需要 TCP Socket，虽然 ESP-IDF Wi-Fi 支持，但其余部分内存不够 |
| **Channels / Providers** | TLS 1.3 + JSON 解析 + LLM API HTTP 调用超出 RAM 预算 |
| **WASM 目标** | 最小 WASI 构建约 900 KB，需要 WASI 运行时，FreeRTOS 上无可用实现 |

---

## 7. 功能对比：所有部署目标

| 功能 | Native | Docker | WASM/WASI | Cloudflare Workers | ESP32（外设模式） |
|---|---|---|---|---|---|
| **LLM 调用**（OpenAI、Anthropic 等） | ✅ | ✅ | ❌ | ❌（JS 宿主调用） | ✅（宿主机侧） |
| **SQLite 记忆后端** | ✅ | ✅ | ❌ | ❌ | ✅（宿主机侧） |
| **消息渠道**（Telegram、Discord 等） | ✅ | ✅ | ❌ | ❌ | ✅（宿主机侧） |
| **HTTP 网关** | ✅ | ✅ | ❌ | ❌ | ✅（宿主机侧） |
| **Shell / 文件系统访问** | ✅ | ✅（挂载） | ❌ | ❌ | ❌（固件侧） |
| **安全沙箱**（Landlock / Firejail 等） | ✅ | ✅ | ❌ | ❌ | N/A |
| **长期运行守护进程** | ✅ | ❌ | ❌ | ❌ | N/A |
| **GPIO 读写**（数字） | ❌ | ❌ | ❌ | ❌ | ✅ GPIO0-GPIO31 |
| **ADC 读**（模拟） | ❌ | ❌ | ❌ | ❌ | ✅ GPIO32-GPIO39 |
| **固件烧录** | ❌ | ❌ | ❌ | ❌ | ✅（`esptool.py`） |
| **Arduino GPIO** | ❌ | ❌ | ❌ | ❌ | ✅（`ArduinoPeripheral`） |
| **STM32/Nucleo 烧录** | ❌ | ❌ | ❌ | ❌ | ✅（`NucleoFlash`） |
| **RPi 原生 GPIO** | ❌ | ❌ | ❌ | ❌ | ✅（`RpiGpioPeripheral`） |
| **硬件自动发现** | ✅ | ✅ | ❌ | ❌ | ✅（宿主机侧） |
| **离线运行**（Ollama） | ✅ | ✅ | ✅（仅关键词） | ❌ | ✅（宿主机侧 + Ollama） |
| **二进制大小** | ~678 KB | ~678 KB | ~900 KB（WASI） | ~4 KB | N/A（固件独立构建） |
| **峰值 RSS** | ~1–5 MB | ~1–5 MB | ~2 MB | < 128 KB | N/A |

### ESP32 vs Arduino vs STM32/Nucleo vs 树莓派：外设横向对比

四种硬件外设均通过相同的 `Peripheral` vtable 接口接入 NullClaw：

| 维度 | ESP32 | Arduino Uno | STM32 Nucleo | 树莓派 GPIO |
|---|---|---|---|---|
| CPU | Xtensa LX6 双核 | AVR ATmega328P | ARM Cortex-M4 | ARM Cortex-A（Linux） |
| 主频 | 240 MHz | 16 MHz | 84–100 MHz | 1–2 GHz |
| SRAM | 520 KB | 2 KB | 128–512 KB | 256 MB – 8 GB |
| Flash | 4 MB | 32 KB | 512 KB | SD 卡（GB 级） |
| GPIO 引脚 | GPIO0-GPIO39（40 个） | D0-D13、A0-A5 | PA0-PC15（因板而异） | 2-27（26 个可用） |
| ADC | 18 通道（12 位） | 6 通道（10 位） | 16 通道（12 位） | 无（硬件不支持） |
| 烧录工具 | `esptool.py` | `arduino-cli` | `probe-rs` | 不支持烧录 |
| GPIO 访问方式 | 串口 JSON | 串口 JSON | `probe-rs read/write` | sysfs `/sys/class/gpio` |
| NullClaw transport | `serial` | `serial` | `probe` / `serial` | `native` |
| 板载 LED | GPIO2 | D13 | PA5 | 无 |
| 内置 Wi-Fi | ✅ | ❌ | ❌ | ✅（通过操作系统） |

---

## 8. 故障排查

### 报错 `DeviceNotFound`（初始化失败）

`esptool.py` 不在 PATH 中。验证：

```bash
esptool.py version
```

若找不到命令：`pip install esptool`。部分系统命令名为 `esptool`（无 `.py`）。

### 报错 `PermissionDenied`（串口无法打开）

Linux 下将用户加入 `dialout` 组：

```bash
sudo usermod -aG dialout $USER
# 重新登录，然后验证：
ls -la /dev/ttyUSB0   # 应显示 crw-rw---- ... dialout
```

### 报错 `IoError` / `Timeout`（GPIO 读写失败）

ESP32 固件未运行 JSON 命令处理器，或波特率不匹配。检查：

1. 固件已烧录并正常运行（串口监视器可见输出）。
2. config 中的 `path` 与实际设备节点匹配（`/dev/ttyUSB0` vs `/dev/ttyUSB1`）。
3. config 中的 `baud` 与固件 UART 速率一致（通常 `115200`）。

### 尝试写入 GPIO32-GPIO39 报错 `UnsupportedOperation`

GPIO32-GPIO39 在 ESP32 上被硬件固定为 ADC1 输入，无法作为数字输出驱动。输出用途请使用 GPIO0-GPIO31。读取模拟电压请用 `gpio_read`（内部自动派发为 `adc_read`）。

### `esptool.py` 报错，烧录失败

- 烧录时按住 BOOT 键（如未接自动复位电路）。
- 降低 config 中的 `baud`（尝试 `57600` 或 `38400`）。
- 确保没有串口监视器等程序已占用该串口。
