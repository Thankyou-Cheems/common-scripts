[English Version](#english-version)

# [PR] Feat: P2P 文件传输功能 (P2P File Transfer)

## 简介 (Introduction)

这个 PR 为 EasyTier 引入了基于 RPC 的点对点文件传输功能，**实现了 [Issue #1770](https://github.com/EasyTier/EasyTier/issues/1770) 的核心功能**。虽然 EasyTier 的核心定位是组网工具，但能够直接在节点间安全传输文件一直是一个高频需求。我通过 CLI 实现了这一功能，旨在提供一个轻量、安全且可控的传输方案。

特别是为了防止公共中继被滥用，与其让用户通过搭建不安全的 HTTP 服务来传文件，不如提供一个内置的、受控的解决方案，让中继运营者有能力限制流量。

### 为什么不直接集成 LocalSend？(Why not LocalSend?)

在开发前我也考虑过集成成熟的 LocalSend，但最终选择了自研 RPC 实现，主要基于：

1. **协议效率 (Protocol Efficiency)**：LocalSend 基于 **HTTP/REST API** 进行通信，需要建立独立的 TCP/HTTPS 连接和 TLS 握手。而 EasyTier 自研 RPC 直接复用现有的 WireGuard/KCP 加密长连接，**无额外握手中转开销**。
2. **网络复用 (Network Reuse)**：LocalSend 依赖组播 (Multicast) 或 IP 扫描进行发现，难以穿透复杂 NAT。EasyTier 已经拥有了最强大的 P2P/Relay 组网能力，复用现有的安全通道可以实现**零配置**的跨网传输。
3. **流量识别与控制 (Traffic Control)**：若使用外部工具，EasyTier 无法区分其流量类型。只有自研协议，EasyTier 才能识别"这是文件传输"，从而让中继节点实施精准的策略控制（如拦截大文件转发）。
4. **单一二进制 (Single Binary)**：EasyTier 的核心哲学是极简部署。引入 LocalSend 会增加外部依赖，破坏"开箱即用"的体验。

**长期规划 (Long-term)**：
文件传输是一个长期的过程。目前的 CLI 实现只是第一步，旨在验证核心 RPC 逻辑和安全模型。**我很愿意持续参与此特性的开发**，未来在核心逻辑稳定后，逐步推进右键菜单集成、GUI 拖拽发送等更高级的交互功能。

## 功能清单 (Features)

- [x] **P2P 文件传输**：优先尝试直连，P2P 不通时自动回退到中继。
- [x] **断点续传**：传输中断后（杀进程或断网），重试命令可从断点继续，基于 SHA256 校验。
- [x] **安全隔离**：强制要求开启 `--private-mode`，防止公网误传。
- [x] **防滥用机制**：中继节点默认**关闭**文件转发，且支持配置大小限制（如 10MB）。
- [x] **仅限 CLI**：目前只实现了 CLI 命令，保持核心简洁，方便小规模验证。
- [x] **测试覆盖**：包含 6 个测试套件，覆盖了直连、中继、限速、断点续传等场景。

---

## 为什么要现在合并？(Why Merge Now?)

虽然这是一个新功能，但我建议尽早合并，主要基于以下**安全考量**：

1. **保护公共中继**：目前的中继节点无法区分普通流量和文件传输流量。合并此 PR 后，中继节点可以通过 `--enable-file-relay false`（默认值）来明确拒绝文件传输请求，保护带宽资源。
2. **无破坏性变更**：所有新参数都是 **Opt-in**（默认关闭）的。现有部署升级后，如果不手动开启 `--enable-file-transfer`，行为完全一致。
3. **小规模验证**：通过 CLI 先行发布，可以收集真实网络环境下的反馈，为未来可能得 GUI 集成积累经验。

---

## 使用方法 (Usage)

### 1. 启动节点

发送端和接收端都需要开启文件传输功能，并设置隐私模式：

```bash
easytier-core --enable-file-transfer true --private-mode true ...
```

### 2. 发送文件

在发送端执行 CLI 命令：

```bash
# 基本用法
easytier-cli file send <PEER_ID> ./my_file.zip

# 示例输出
# Sending file: my_file.zip
# [############################] 100% (2.5 MB/s)
# √ Transfer completed successfully!
```

如果传输中断，再次执行相同命令即可自动续传：

```bash
# 自动检测断点
# [!] Resuming transfer from 45% ...
```

### 3. 中继配置（可选）

对于自建中继服务器，如果你想允许文件转发但限制大小：

```bash
# 允许最大 100MB 的文件通过中继
easytier-core --relay-all-peer-rpc true \
              --enable-file-relay true \
              --file-relay-limit 100
```

对于公共中继，建议保持默认（关闭文件转发），或者设置极小的限制（如 5MB）：

```bash
# 仅允许传输小文件
easytier-core ... --file-foreign-limit 5
```

---

## 详细变更 (Detailed Changes)

### 新增配置参数 (New Configuration Parameters)

本 PR 引入了 5 个新的配置参数，全部默认为关闭/保守策略：

| 参数名 | 类型 | 默认值 | 用途 | 源码位置 |
|--------|------|--------|------|----------|
| `--enable-file-transfer` | bool | `false` | 文件传输总开关 | [`core.rs:646`](../easytier/src/core.rs#L646) |
| `--private-mode` | bool | `false` | 强制隐私模式（文件传输前置要求） | [`core.rs:596`](../easytier/src/core.rs#L596) |
| `--file-relay-limit` | u64 (MB) | `100` | 私有中继最大文件限制 | [`core.rs:654`](../easytier/src/core.rs#L654) |
| `--file-foreign-limit` | u64 (MB) | `10` | 跨网中继最大文件限制（更严格） | [`core.rs:657`](../easytier/src/core.rs#L657) |
| `--enable-file-relay` | bool | `false` | 中继节点是否转发文件传输请求 | [`core.rs:661`](../easytier/src/core.rs#L661) |

#### 限流策略详解 (Limit Hierarchy)

为了平衡私有网络的灵活性和公共中继的安全性，限制策略采用**层层过滤**机制，而非简单的参数覆盖：

1. **总开关 (`--enable-file-relay`)**：优先级最高。若为 `false`，拒绝所有中继传输。
2. **私有中继**：受 `--file-relay-limit` 限制（默认 100MB）。
3. **公共/跨网中继**：**同时**受 `--file-relay-limit` 和 `--file-foreign-limit` 限制。实际生效限额为两者的**最小值**（通常取决于更严格的 `--file-foreign-limit`，默认 10MB）。

这种设计确保了即使你配置了宽松的中继策略，跨网流量依然会被默认的严格策略拦截，防止带宽滥用。

### 为什么不更新 README？(Why No README Update?)

此功能当前处于 **CLI-only 验证阶段**，暂未更新项目主 README 文档，主要考虑：

1. **功能不够成熟**：缺少 GUI 集成，对普通用户不够友好。
2. **避免过早推广**：README 更新会引导大量用户尝试，而当前版本更适合技术用户在真实网络环境中验证核心逻辑。
3. **迭代空间**：CLI 阶段允许我根据反馈快速调整参数或协议，而无需担心大规模兼容性问题。

待功能稳定且有明确的 GUI roadmap 后，会正式纳入主文档。

### 协议设计

采用了 gRPC-style 的定义（见 [`file_transfer.proto`](../easytier/src/proto/file_transfer.proto)），流程如下：

1. **Offer**: 发送者发起请求，接收者检查大小限制和权限（[`service.rs:168-210`](../easytier/src/file_transfer/service.rs#L168-L210)）。
2. **Pull**: 接收者主动拉取分块（Chunk），每块 64KB（[`service.rs:295-340`](../easytier/src/file_transfer/service.rs#L295-L340)）。
3. **Verify**: 传输完成后校验全文件 SHA256（[`service.rs:350-370`](../easytier/src/file_transfer/service.rs#L350-L370)）。

---

## 测试情况 (Test Coverage)

所有测试脚本位于 `easytier-test/` 目录下，均已通过：

<details>
<summary>点击展开测试详情</summary>

- [x] `test_transfer_p2p_basic` - 基础 P2P 传输
- [x] `test_transfer_p2p_large` - 20MB 大文件传输
- [x] `test_transfer_relay_policy` - 中继策略控制
- [x] `test_transfer_relay_limits` - 大小限制测试
- [x] `test_transfer_security_gates` - 隐私模式和开关测试
- [x] `test_transfer_resumability` - 断点续传测试

</details>

### 演示Demo

我编写了完整的测试套件和交互式演示脚本来验证功能：

1. **自动化测试**：
   位于 `easytier-test/` 目录下，包含基础 P2P、中继策略、断点续传等测试。
   ```bash
   # 运行全量测试
   ./easytier-test/run_tests.ps1 -PublicRelayHost <RELAY_IP>
   ```
   *注：不带参数运行将跳过需外部中继的测试用例。*

2. **交互式演示**：
   位于 `scripts/` 目录下，用于手动体验传输流程。
   ```powershell
   # 启动两个本地节点进行文件传输演示
   ./scripts/demo_file_transfer_p2p.ps1
   ```

---

<br>
<br>

<a id="english-version"></a>
# [PR] Feat: P2P File Transfer via RPC

## Introduction

This PR introduces a built-in P2P file transfer capability to EasyTier. While EasyTier is primarily a networking tool, the ability to securely transfer files between nodes is a highly requested feature. I implemented this via CLI to provide a lightweight, secure, and controllable solution.

Crucially, this feature is designed to **protect public relays from abuse**. Instead of users setting up insecure HTTP services for file transfer, providing a controlled, built-in solution allows relay operators to manage and throttle this traffic effectively.

### Why not integrate LocalSend?

I considered allowing integration with LocalSend, but chose a native RPC implementation for distinct advantages:

1. **Protocol Efficiency**: LocalSend uses **HTTP/REST API** which requires establishing new TCP/HTTPS connections and TLS handshakes. EasyTier's RPC multiplexes over the existing authenticated WireGuard/KCP tunnels, resulting in **zero handshake overhead**.
2. **Network Traversal**: LocalSend relies on Multicast UDP or HTTP scanning, which fails across NATs or subnets. EasyTier utilizes its existing robust P2P mesh, allowing file transfer anywhere logical connectivity exists without extra config.
3. **Traffic Control**: External tools treat EasyTier as a dumb pipe. By using a native protocol, EasyTier relays can distinguish file transfer traffic from VPN traffic, enabling the granular security policies (like blocking forwarded file transfers) central to this PR.
4. **Single Binary Dependency**: Integrating LocalSend would require shipping additional binaries, complicating deployment. EasyTier remains a standalone, static binary.

**Long-term Commitment**:
File transfer is a marathon, not a sprint. This CLI implementation is just the first step to validate the core RPC logic and security model. **I am committed to maintaining this feature** and potentially extending it with context menu integration and GUI drag-and-drop support in the future as the core stabilizes.

## Features

- [x] **P2P File Transfer**: Tries direct connection first, falls back to relay if P2P fails.
- [x] **Resumable Transfers**: Automatically resumes from where it left off (SHA256 verified) if interrupted.
- [x] **Security**: Requires `--private-mode` to prevent accidental exposure on public networks.
- [x] **Anti-Abuse**: Relay nodes disable file forwarding by default; supports size limits (e.g., 10MB limit).
- [x] **CLI Only**: Kept minimal for now to validate demand and stability.
- [x] **Test Coverage**: Includes 6 suites covering P2P, relay, limits, and resume scenarios.

---

## Why Merge Now?

Even though this is a new feature, early merging is recommended for **security reasons**:

1. **Protect Public Relays**: Current relays cannot distinguish file transfer traffic. With this PR, relays can explicitly reject file transfers via `--enable-file-relay false` (default), protecting their bandwidth.
2. **Opt-in Only**: All new parameters default to `false`. Existing deployments are unaffected unless manually enabled.
3. **Field Validation**: Releasing via CLI allows us to gather real-world data before considering any GUI integration.

---

## Usage

### 1. Start Nodes

Enable file transfer and private mode on both sender and receiver:

```bash
easytier-core --enable-file-transfer true --private-mode true ...
```

### 2. Send File

Run the CLI command on the sender:

```bash
# Basic usage
easytier-cli file send <PEER_ID> ./my_file.zip

# Output
# Sending file: my_file.zip
# [############################] 100% (2.5 MB/s)
# √ Transfer completed successfully!
```

Retry the same command to resume if interrupted:

```bash
# Auto-detects partial file
# [!] Resuming transfer from 45% ...
```

### 3. Relay Configuration (Optional)

For self-hosted relays, you might want to allow file forwarding with a limit:

```bash
# Allow max 100MB through relay
easytier-core --relay-all-peer-rpc true \
              --enable-file-relay true \
              --file-relay-limit 100
```

For public relays, stick to defaults (disabled) or set a very low limit:

```bash
# Restrict foreign traffic
easytier-core ... --file-foreign-limit 5
```

---

## Detailed Changes

### New Configuration Parameters

This PR introduces 5 new parameters, all defaulting to off/conservative:

| Parameter | Type | Default | Purpose | Source Code |
|-----------|------|---------|---------|-------------|
| `--enable-file-transfer` | bool | `false` | Master switch for file transfer | [`core.rs:646`](../easytier/src/core.rs#L646) |
| `--private-mode` | bool | `false` | Enforces private network isolation (required for file transfer) | [`core.rs:596`](../easytier/src/core.rs#L596) |
| `--file-relay-limit` | u64 (MB) | `100` | Max file size via private relay | [`core.rs:654`](../easytier/src/core.rs#L654) |
| `--file-foreign-limit` | u64 (MB) | `10` | Max file size via foreign relay (stricter) | [`core.rs:657`](../easytier/src/core.rs#L657) |
| `--enable-file-relay` | bool | `false` | Whether relay nodes forward file transfer RPCs | [`core.rs:661`](../easytier/src/core.rs#L661) |

#### Limit Hierarchy Explained

To balance private network flexibility with public relay security, the limit policy uses a **multi-layered filtering** mechanism rather than simple parameter overwriting:

1. **Master Switch (`--enable-file-relay`)**: Highest priority. If `false`, all relayed transfers are rejected.
2. **Private Relay**: Subject to `--file-relay-limit` (default 100MB).
3. **Public/Foreign Relay**: Subject to **BOTH** `--file-relay-limit` and `--file-foreign-limit`. The effective limit is the **minimum** of the two (usually the stricter `--file-foreign-limit`, default 10MB).

This design ensures that even if you configure a generous relay policy for your own nodes, cross-network traffic remains restricted by default to prevent bandwidth abuse.

### Why No README Update?

This feature is currently in **CLI-only validation phase** and has not been added to the main README, for these reasons:

1. **Not Mature Enough**: Lacks GUI integration, making it less friendly for average users.
2. **Avoid Premature Exposure**: A README update would drive mass adoption before the core logic is battle-tested by power users.
3. **Iteration Flexibility**: CLI-only allows me to rapidly adjust parameters or protocol based on feedback without breaking compatibility at scale.

Once the feature stabilizes and there's a clear GUI roadmap, it will be promoted to the main documentation.

### Protocol


Implemented using gRPC-like definitions in [`file_transfer.proto`](../easytier/src/proto/file_transfer.proto):

1. **Offer**: Sender initiates; Receiver checks limits/permissions ([`service.rs:168-210`](../easytier/src/file_transfer/service.rs#L168-L210)).
2. **Pull**: Receiver requests chunks, 64KB each ([`service.rs:295-340`](../easytier/src/file_transfer/service.rs#L295-L340)).
3. **Verify**: Full SHA256 check upon completion ([`service.rs:350-370`](../easytier/src/file_transfer/service.rs#L350-L370)).

---

## Test Coverage

<details>
<summary>Click to view test details</summary>

- [x] `test_transfer_p2p_basic` - Basic P2P transfer
- [x] `test_transfer_p2p_large` - 20MB file handling
- [x] `test_transfer_relay_policy` - Relay control policies
- [x] `test_transfer_relay_limits` - Size limit enforcement
- [x] `test_transfer_security_gates` - Private mode & switches
- [x] `test_transfer_resumability` - Interrupt/Resume logic

</details>

### Demo

I have included a comprehensive test suite and an interactive demo script:

1. **Automated Tests**:
   Located in `easytier-test/`, covering P2P transfer, relay policies, resumability, etc.
   ```bash
   # Run full test suite (requires external relay for some tests)
   ./easytier-test/run_tests.ps1 -PublicRelayHost <RELAY_IP>
   ```
   *Note: Running without arguments skips tests requiring an external relay.*

2. **Interactive Demo**:
   Located in `scripts/`, for manual verification of the user experience.
   ```powershell
   # Start two local nodes for file transfer demo
   ./scripts/demo_file_transfer_p2p.ps1
   ```

All test scripts pass locally.
ript:

1. **Automated Tests**:
   Located in `easytier-test/`, covering P2P transfer, relay policies, resumability, etc.
   ```bash
   # Run full test suite
   ./easytier-test/run_tests.ps1
   ```

2. **Interactive Demo**:
   Located in `scripts/`, for manual verification of the user experience.
   ```powershell
   # Start two local nodes for file transfer demo
   ./scripts/demo_file_transfer_p2p.ps1
   ```

All test scripts pass locally.

<details>
<summary>Click to view test details</summary>

- [x] `test_transfer_p2p_basic` - Basic P2P transfer
- [x] `test_transfer_p2p_large` - 20MB file handling
- [x] `test_transfer_relay_policy` - Relay control policies
- [x] `test_transfer_relay_limits` - Size limit enforcement
- [x] `test_transfer_security_gates` - Private mode & switches
- [x] `test_transfer_resumability` - Interrupt/Resume logic

</details>
