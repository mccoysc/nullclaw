# MQTT & Redis Stream Channels

NullClaw supports **MQTT** and **Redis Stream** as messaging channels. Both channels use **ECDSA P256 (secp256r1)** signatures for message authentication: inbound messages are verified against the peer's public key, and outbound messages are signed with the local private key.

## Quick Start

Run the onboarding wizard to configure a channel interactively:

```bash
nullclaw onboard
```

The wizard will prompt you for broker/server details, the peer's public key, and the topic/stream to listen on. It automatically generates:

- A random P256 keypair (local private key + public key)
- A unique `endpoint_id` (16-char hex) for stable session tracking

After onboarding, share your **local public key** with the peer so they can verify messages you send.

## Configuration

All channel configuration lives in `config.json` under the `channels` section.

### MQTT

```jsonc
{
  "channels": {
    "mqtt": [
      {
        "account_id": "default",
        "endpoints": [
          {
            "endpoint_id": "a1b2c3d4e5f67890",
            "host": "broker.example.com",
            "port": 1883,
            "username": "user",          // optional
            "password": "pass",          // optional
            "tls": false,
            "client_id": "my-client",    // optional, auto-generated if omitted
            "peer_pubkey": "<peer P256 public key, hex, uncompressed SEC1, 130 chars>",
            "local_privkey": "<local P256 private key, hex, 64 chars>",
            "local_pubkey": "<local P256 public key, hex, uncompressed SEC1, 130 chars>",
            "listen_topic": "chat/inbound",
            "reply_topic": "chat/outbound",  // optional, defaults to listen_topic
            "model_override": {              // optional, per-endpoint model config
              "provider": "openrouter",
              "model": "openrouter/minimax/minimax-m2.5",
              "max_context_tokens": 8192,
              "temperature": 0.7
            }
          }
        ]
      }
    ]
  }
}
```

### Redis Stream

```jsonc
{
  "channels": {
    "redis_stream": [
      {
        "account_id": "default",
        "endpoints": [
          {
            "endpoint_id": "f0e1d2c3b4a59687",
            "host": "localhost",
            "port": 6379,
            "username": "default",       // optional (Redis 6+ ACL)
            "password": "secret",        // optional
            "db": 0,
            "tls": false,
            "peer_pubkey": "<peer P256 public key, hex, uncompressed SEC1, 130 chars>",
            "local_privkey": "<local P256 private key, hex, 64 chars>",
            "local_pubkey": "<local P256 public key, hex, uncompressed SEC1, 130 chars>",
            "listen_topic": "mystream:inbound",
            "reply_topic": "mystream:outbound",  // optional, defaults to listen_topic
            "consumer_group": "nullclaw",         // default: "nullclaw"
            "consumer_name": "default",           // default: "default"
            "model_override": {}                  // optional
          }
        ]
      }
    ]
  }
}
```

## Configuration Fields

### Common Fields (MQTT & Redis Stream)

| Field | Required | Description |
|-------|----------|-------------|
| `endpoint_id` | No | Unique hex identifier for this endpoint. Auto-generated during onboarding. Used for stable session tracking across config hot-reloads. |
| `peer_pubkey` | Yes | The peer's P256 public key in hex (uncompressed SEC1 format, 130 hex chars). Used to verify inbound messages. |
| `local_privkey` | Yes | Your local P256 private key in hex (64 hex chars). Used to sign outbound messages. |
| `local_pubkey` | Yes | Your local P256 public key in hex (uncompressed SEC1 format, 130 hex chars). Derived from `local_privkey`. Published so the peer can verify your signatures. |
| `listen_topic` | Yes | The topic/stream key to subscribe to for inbound messages. |
| `reply_topic` | No | The topic/stream key to publish replies on. If omitted or equal to `listen_topic`, single-topic mode is used (see below). |
| `model_override` | No | Per-endpoint model configuration. Overrides global `provider`, `model`, `max_context_tokens`, and `temperature`. |

### MQTT-Specific Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | Yes | - | MQTT broker hostname. |
| `port` | No | `1883` | Broker port (1883 for TCP, 8883 for TLS). |
| `username` | No | - | Broker authentication username. |
| `password` | No | - | Broker authentication password. |
| `tls` | No | `false` | Enable TLS for the connection. |
| `client_id` | No | auto | MQTT client ID. Auto-generated if not set. |

### Redis Stream-Specific Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | No | `localhost` | Redis server hostname. |
| `port` | No | `6379` | Redis server port. |
| `username` | No | - | Redis 6+ ACL username. |
| `password` | No | - | Redis AUTH password. |
| `db` | No | `0` | Redis database index. |
| `tls` | No | `false` | Enable TLS for the connection. |
| `consumer_group` | No | `nullclaw` | Consumer group name for `XREADGROUP`. |
| `consumer_name` | No | `default` | Consumer name within the group. |

## Wire Format

All messages are cryptographically signed. The wire format differs slightly between MQTT and Redis Stream.

### MQTT Wire Format

Each MQTT payload is a JSON object:

```json
{
  "pubkey": "<sender's P256 public key, hex>",
  "sig": "<ECDSA P256-SHA256 signature, hex, 128 chars>",
  "body": "<message body, base64-encoded>"
}
```

### Redis Stream Wire Format

Each Redis Stream entry contains three fields:

```
pubkey  <sender's P256 public key, hex>
sig     <ECDSA P256-SHA256 signature, hex, 128 chars>
body    <message body, base64-encoded>
```

Published via `XADD <stream> * pubkey <hex> sig <hex> body <base64>`.

### Signature Process

**Sending:**
1. The raw message body is signed using the local P256 private key (ECDSA P256-SHA256).
2. The message body is base64-encoded.
3. The payload is assembled with the local public key, signature, and encoded body.

**Receiving:**
1. Parse the inbound payload to extract `pubkey`, `sig`, and `body`.
2. In single-topic mode, check if `pubkey` matches our own `local_pubkey` -- if so, discard (it's our own message).
3. Verify that `pubkey` matches the configured `peer_pubkey` -- reject if not.
4. Base64-decode the body.
5. Verify the signature against the decoded body using the peer's public key.
6. If verification passes, the decoded body is forwarded to the session for processing.

## Single-Topic Mode

When `reply_topic` is omitted or set to the same value as `listen_topic`, the channel operates in **single-topic mode**: both inbound and outbound messages share the same topic/stream.

In this mode, the channel automatically filters out messages signed by our own key (`pubkey == local_pubkey`) to avoid processing messages we sent ourselves.

## Multiple Endpoints

Each channel type supports multiple endpoints within the same account, and multiple accounts. Every endpoint runs its own independent listener thread and maintains its own session.

```jsonc
{
  "channels": {
    "mqtt": [
      {
        "account_id": "production",
        "endpoints": [
          { "endpoint_id": "aaa...", "host": "broker1.example.com", "listen_topic": "device/1", ... },
          { "endpoint_id": "bbb...", "host": "broker1.example.com", "listen_topic": "device/2", ... },
          { "endpoint_id": "ccc...", "host": "broker2.example.com", "listen_topic": "alerts", ... }
        ]
      },
      {
        "account_id": "staging",
        "endpoints": [
          { "endpoint_id": "ddd...", "host": "staging-broker.example.com", "listen_topic": "test", ... }
        ]
      }
    ]
  }
}
```

Each endpoint creates an independent session, so conversations on different endpoints do not interfere with each other.

## Per-Endpoint Model Override

Each endpoint can override the global LLM model configuration. When set, these values take precedence over the global `provider`, `model`, `max_context_tokens`, and `temperature` settings for sessions created from that endpoint.

```jsonc
{
  "endpoint_id": "abc123...",
  "host": "broker.example.com",
  "listen_topic": "support",
  "model_override": {
    "provider": "anthropic",
    "model": "claude-sonnet-4-20250514",
    "max_context_tokens": 16384,
    "temperature": 0.5
  },
  ...
}
```

If `model_override` is not set (or all its fields are null/zero), the endpoint inherits the global model configuration. When `max_context_tokens` is reached, context auto-compaction is triggered automatically.

## Session Tracking with endpoint_id

Each endpoint has a unique `endpoint_id` (auto-generated during onboarding as a 16-char random hex string). This ID is used to:

1. **Build session keys**: Sessions are keyed as `mqtt:<endpoint_id>` or `redis_stream:<endpoint_id>`, ensuring stable session identity across config changes.
2. **Hot-reload correlation**: When the config file changes, the system uses `endpoint_id` to match running sessions with config entries and determine the correct action (see [CONFIG-HOT-RELOAD.md](CONFIG-HOT-RELOAD.md)).

If `endpoint_id` is missing (e.g., manually edited config), the session key falls back to `{channel_type}:{account_id}:{topic}`.

## Prerequisites

### MQTT

The MQTT channel uses the `mosquitto_sub` and `mosquitto_pub` CLI tools. Install them:

```bash
# Debian / Ubuntu
sudo apt install mosquitto-clients

# macOS
brew install mosquitto

# Alpine
apk add mosquitto-clients
```

### Redis Stream

The Redis Stream channel uses the `redis-cli` tool. Install it:

```bash
# Debian / Ubuntu
sudo apt install redis-tools

# macOS
brew install redis

# Alpine
apk add redis
```

## Client Example (Python)

Here is a minimal Python script to send a signed message to an MQTT channel and receive the response:

```python
import json, base64, hashlib, secrets
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization
import paho.mqtt.client as mqtt

# Load your keypair
PRIVATE_KEY = ec.generate_private_key(ec.SECP256R1())
PUBLIC_KEY = PRIVATE_KEY.public_key()

# The NullClaw instance's public key (from its config)
NULLCLAW_PUBKEY_HEX = "<paste local_pubkey from nullclaw config>"

BROKER = "broker.example.com"
TOPIC = "chat/inbound"

def pubkey_hex(key):
    return key.public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint
    ).hex()

def sign_message(message: str) -> str:
    body_bytes = message.encode()
    sig = PRIVATE_KEY.sign(body_bytes, ec.ECDSA(hashes.SHA256()))
    # P256 signature in DER -> raw r||s (64 bytes)
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    r, s = decode_dss_signature(sig)
    sig_raw = r.to_bytes(32, 'big') + s.to_bytes(32, 'big')
    return json.dumps({
        "pubkey": pubkey_hex(PUBLIC_KEY),
        "sig": sig_raw.hex(),
        "body": base64.b64encode(body_bytes).decode()
    })

# Publish
client = mqtt.Client()
client.connect(BROKER)
client.publish(TOPIC, sign_message("Hello NullClaw!"))
client.disconnect()
```

> **Note**: When configuring NullClaw, set `peer_pubkey` to the hex-encoded public key of the client script shown above.
