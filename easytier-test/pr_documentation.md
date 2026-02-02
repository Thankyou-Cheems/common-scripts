[English Version](#english-version)

# [PR] Feat: P2P 文件传输功能 (P2P File Transfer)

## 简介 (Introduction)

这个 PR 为 EasyTier 引入了基于 RPC 的点对点文件传输功能，**实现了 [Issue #1770](https://github.com/EasyTier/EasyTier/issues/1770) 的核心功能**。虽然 EasyTier 的核心定位是组网工具，但能够直接在节点间安全传输文件一直是一个高频需求。我通过 CLI 实现了这一功能，旨在提供一个轻量、安全且可控的传输方案。

特别是为了避免公共中继被滥用，与其让用户通过搭建不安全的 HTTP 服务来传文件，不如提供一个内置的、受控的解决方案，让接收端可选择拒绝经由中继的文件传输，同时中继运营者也能通过带宽/网络策略进行限流。

### 为什么不直接集成 LocalSend？(Why not LocalSend?)

在开发前我也考虑过集成成熟的 LocalSend，但最终选择了自研 RPC 实现，主要基于：

1. **协议效率 (Protocol Efficiency)**：LocalSend 基于 **HTTP/REST API** 进行通信，需要建立独立的 TCP/HTTPS 连接和 TLS 握手。而 EasyTier 自研 RPC 直接复用现有的 WireGuard/KCP 加密长连接，**无额外握手中转开销**。
2. **网络复用 (Network Reuse)**：LocalSend 依赖组播 (Multicast) 或 IP 扫描进行发现，难以穿透复杂 NAT。EasyTier 已经拥有了最强大的 P2P/Relay 组网能力，复用现有的安全通道可以实现**零配置**的跨网传输。
3. **流量识别与控制 (Traffic Control)**：若使用外部工具，EasyTier 无法区分其流量类型。自研协议允许识别"这是文件传输"，接收端可基于是否经由中继进行策略控制（拒绝/限额），中继侧保持透明转发以避免性能开销。
4. **单一二进制 (Single Binary)**：EasyTier 的核心哲学是极简部署。引入 LocalSend 会增加外部依赖，破坏"开箱即用"的体验。

**长期规划 (Long-term)**：
文件传输是一个长期的过程。目前的 CLI 实现只是第一步，旨在验证核心 RPC 逻辑和安全模型。**我很愿意持续参与此特性的开发**，未来在核心逻辑稳定后，逐步推进右键菜单集成、GUI 拖拽发送等更高级的交互功能。

## 功能清单 (Features)

- [x] **P2P 文件传输**：优先尝试直连，P2P 不通时自动回退到中继。
- [x] **断点续传**：传输中断后（杀进程或断网），重试命令可从断点继续，基于 SHA256 校验。
- [x] **安全隔离**：强制要求开启 `--private-mode`，防止公网误传。
- [x] **防滥用机制**：接收端可拒绝经由中继的传输，并支持中继/跨网的大小限制；中继侧不做应用层解码。
- [x] **仅限 CLI**：目前只实现了 CLI 命令，保持核心简洁，方便小规模验证。
- [x] **测试覆盖**：包含 6 个测试套件，覆盖了直连、中继、限速、断点续传等场景。

---

## 为什么要现在合并？(Why Merge Now?)

虽然这是一个新功能，但我建议尽早合并，主要基于以下**安全考量**：

1. **保护公共中继**：通过接收端拒绝中继与跨网大小/带宽限制，降低公共中继被滥用的风险。
2. **无破坏性变更**：所有新参数都是 **Opt-in**（默认关闭）的。现有部署升级后，如果不手动开启 `--enable-file-transfer`，行为完全一致。
3. **小规模验证**：通过 CLI 先行发布，可以收集真实网络环境下的反馈，为未来可能的 GUI 集成积累经验。

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

### 3. 中继与接收端策略（可选）

中继节点无需额外开关，启用 `--relay-all-peer-rpc` 后会透明转发 RPC。限制策略由**接收端**执行，可按需选择：

```bash
# 接收端允许中继但限制大小（例如 100MB）
easytier-core --enable-file-transfer true --private-mode true \
              --file-relay-limit 104857600
```

对于公共/跨网中继，建议设置更严格的限制或直接拒绝：

```bash
# 仅允许传输小文件 (5MB = 5,242,880 Bytes)
easytier-core ... --file-foreign-limit 5242880

# 或直接拒绝中继到达的文件传输
easytier-core ... --disable-file-from-relay
```

---

## 详细变更 (Detailed Changes)

### 配置参数说明 (Configuration Parameters)

本 PR 引入了 4 个新的配置参数，并复用了现有的 `--private-mode`，全部默认为关闭/保守策略：

| 参数名 | 类型 | 默认值 | 用途 | 源码位置 |
|--------|------|--------|------|----------|
| `--enable-file-transfer` | bool | `false` | [新增] 文件传输总开关 | [`core.rs:632`](../easytier/src/core.rs#L632) |
| `--private-mode` | bool | `false` | [依赖] 必须开启，确保传输仅在受信任的私有网络内进行 | [`core.rs:543`](../easytier/src/core.rs#L543) |
| `--file-relay-limit` | u64 (Bytes) | `0` (Unlimited) | [新增] 中继大小限制，防止误用带宽紧张的链路 | [`core.rs:647`](../easytier/src/core.rs#L647) |
| `--file-foreign-limit` | u64 (Bytes) | `4194304` (4MB) | [新增] 跨网中继大小限制（更严格），保护公共资源 | [`core.rs:650`](../easytier/src/core.rs#L650) |
| `--disable-file-from-relay` | bool | `false` | [新增] 接收端拒绝经由中继转发的文件传输 | [`core.rs:639`](../easytier/src/core.rs#L639) |
| `--foreign-relay-bps-limit` | u64 (Bytes/s) | `Unlimited` | [现有] 跨网中继的带宽速率限制 | [`core.rs:550`](../easytier/src/core.rs#L550) |

#### 限流策略详解 (Limit Hierarchy)
 
为了平衡私有网络的灵活性和公共中继的安全性，将配置逻辑分为两个核心场景：
 
**场景一：自建私有中继 (My Relay, My Rules)**
*   **配置目标**：允许文件在我的设备间通过我自己搭建的中继传输。
*   **关键参数**：
    *   `--file-relay-limit <BYTES>`: 设置允许的最大文件大小（默认 0/无限）。
    *   `--disable-file-from-relay`: 若只允许 P2P，可由接收端主动拒绝中继传输。
*   **说明**：这是最宽松的模式，信任链覆盖所有节点，依靠同名同密网络。
 
**场景二：使用公共/他人中继 (Protecting Others & Self)**
*   **配置目标**：防止公共中继被滥用，同时保护自己不通过昂贵链路传大文件。
*   **作为中继提供者（保护自己）**：
    *   `--foreign-relay-bps-limit <BYTES/S>`: 进一步限制跨网流量的带宽速率，防止拥塞。
*   **作为终端用户（保护自己）**：
    *   `--file-foreign-limit <BYTES>`: 对跨网（Foreign）的文件传输设置更严格的大小限制（默认 4MB）。
    *   `--disable-file-from-relay`: 接收端拒绝非直连（P2P）的文件传输。防止 P2P 打洞失败后，流量意外走公共中继消耗流量或产生费用。
 
限制取**最小值**。如果流量跨网（Foreign），则同时受 `--file-relay-limit`（基础限制）和 `--file-foreign-limit`（跨网限制）的双重约束。

### 破坏性变更 (Breaking Changes)

- `--enable-file-relay` 已移除（中继侧转发控制），中继默认透传 RPC，不再做应用层解码。
- `--disable-file-transfer-relay` 更名为 `--disable-file-from-relay`。
- 协议兼容性保持不变（protobuf 字段号不复用）。
- 性能：移除中继侧 RPC 解码，转发路径 CPU 开销显著降低。

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
   测试脚本已开源在 [Thankyou-Cheems/common-scripts](https://github.com/Thankyou-Cheems/common-scripts/tree/master/easytier-test)。
   ```bash
   # 运行全量测试 (需下载脚本)
   pwsh ./easytier-test/run_tests.ps1 -PublicRelayHost <RELAY_IP>
   ```
   *注：不带参数运行将跳过需外部中继的测试用例。*

2. **交互式演示**：
   同样位于上述仓库中，用于手动体验传输流程。
   ```powershell
   # 启动两个本地节点进行文件传输演示
   pwsh ./easytier-test/demo_file_transfer_p2p.ps1
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
3. **Traffic Control**: External tools treat EasyTier as a dumb pipe. A native protocol lets us identify file transfer traffic and enforce policies on the receiver side (reject/limit relayed transfers) while keeping relays transparent to avoid decode overhead.
4. **Single Binary Dependency**: Integrating LocalSend would require shipping additional binaries, complicating deployment. EasyTier remains a standalone, static binary.

**Long-term Commitment**:
File transfer is a marathon, not a sprint. This CLI implementation is just the first step to validate the core RPC logic and security model. **I am committed to maintaining this feature** and potentially extending it with context menu integration and GUI drag-and-drop support in the future as the core stabilizes.

## Features

- [x] **P2P File Transfer**: Tries direct connection first, falls back to relay if P2P fails.
- [x] **Resumable Transfers**: Automatically resumes from where it left off (SHA256 verified) if interrupted.
- [x] **Security**: Requires `--private-mode` to prevent accidental exposure on public networks.
- [x] **Anti-Abuse**: Receiver can reject relayed transfers and enforce size limits; relays stay transparent (no app-layer decode).
- [x] **CLI Only**: Kept minimal for now to validate demand and stability.
- [x] **Test Coverage**: Includes 6 suites covering P2P, relay, limits, and resume scenarios.

---

## Why Merge Now?

Even though this is a new feature, early merging is recommended for **security reasons**:

1. **Protect Public Relays**: Receiver-side reject/limit policies plus cross-network size/bandwidth limits reduce the risk of relay abuse.
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

### 3. Relay & Receiver Policies (Optional)

Relays do not need a special switch; once `--relay-all-peer-rpc` is enabled they forward RPCs transparently. Policy is enforced on the **receiver**:

```bash
# Receiver allows relay but limits size (e.g. 100MB)
easytier-core --enable-file-transfer true --private-mode true \
              --file-relay-limit 104857600
```

For public/foreign relays, apply stricter limits or reject relayed transfers:

```bash
# Restrict foreign traffic (5MB = 5,242,880 Bytes)
easytier-core ... --file-foreign-limit 5242880

# Or reject relayed file transfers entirely
easytier-core ... --disable-file-from-relay
```

---

## Detailed Changes

### Configuration Parameters

This PR introduces 4 new parameters and reuses the existing `--private-mode`. All conform to a closed-by-default/conservative policy:

| Parameter | Type | Default | Purpose | Source Code |
|-----------|------|---------|---------|-------------|
| `--enable-file-transfer` | bool | `false` | [NEW] Master switch for file transfer | [`core.rs:632`](../easytier/src/core.rs#L632) |
| `--private-mode` | bool | `false` | [EXISTING] Required to ensure transfers occur within trusted private networks | [`core.rs:543`](../easytier/src/core.rs#L543) |
| `--file-relay-limit` | u64 (Bytes) | `0` (Unlimited) | [NEW] Relay size limit to prevent bandwidth exhaustion | [`core.rs:647`](../easytier/src/core.rs#L647) |
| `--file-foreign-limit` | u64 (Bytes) | `4194304` (4MB) | [NEW] Stricter limit for foreign/public relays | [`core.rs:650`](../easytier/src/core.rs#L650) |
| `--disable-file-from-relay` | bool | `false` | [NEW] Reject incoming file transfers if relayed | [`core.rs:639`](../easytier/src/core.rs#L639) |
| `--foreign-relay-bps-limit` | u64 (Bytes/s) | `Unlimited` | [EXISTING] Bandwidth rate limit for foreign relay traffic | [`core.rs:550`](../easytier/src/core.rs#L550) |

#### Limit Hierarchy
 
To balance private network flexibility with public relay security, we categorize configuration logic into two core scenarios:
 
**Scenario 1: Self-hosted/Private Relay (My Relay, My Rules)**
*   **Goal**: Allow file transfers between my devices via my own relay.
*   **Key Parameters**:
    *   `--file-relay-limit <BYTES>`: Set maximum allowed file size (default 0/Unlimited).
    *   `--disable-file-from-relay`: If you want P2P-only, receiver can reject relayed transfers.
*   **Context**: This is the most permissive mode, relying on the trust relationship within a private network.
 
**Scenario 2: Using Public/Third-party Relay (Protecting Others & Self)**
*   **Goal**: Prevent public relay abuse while protecting oneself from expensive large transfers.
*   **As Relay Provider (Protecting Self)**:
    *   `--foreign-relay-bps-limit <BYTES/S>`: Further limit bandwidth rate for cross-network traffic to prevent congestion.
*   **As End-User (Protecting Self)**:
    *   `--file-foreign-limit <BYTES>`: Apply stricter size limits to foreign relay transfers (default 4MB).
    *   `--disable-file-from-relay`: Receiver proactively rejects non-P2P transfers. Prevents accidental data consumption via public relays if P2P fails.
 
Limits apply as the **minimum**. If traffic is cross-network (Foreign), it is constrained by both `--file-relay-limit` (Basic) and `--file-foreign-limit` (Foreign).

### Breaking Changes

- `--enable-file-relay` removed (relay-side forwarding control); relays now forward RPCs without app-layer decoding.
- `--disable-file-transfer-relay` renamed to `--disable-file-from-relay`.
- Wire compatibility unchanged (protobuf field numbers retained).
- Performance: relay path no longer decodes RPC packets, reducing CPU overhead.

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
   Scripts are available at [Thankyou-Cheems/common-scripts](https://github.com/Thankyou-Cheems/common-scripts/tree/master/easytier-test).
   ```bash
   # Run full test suite (requires script download)
   pwsh ./easytier-test/run_tests.ps1 -PublicRelayHost <RELAY_IP>
   ```
   *Note: Running without arguments skips tests requiring an external relay.*

2. **Interactive Demo**:
   Also available in the repository above, for manual verification.
   ```powershell
   # Start two local nodes for file transfer demo
   pwsh ./easytier-test/demo_file_transfer_p2p.ps1
   ```

All test scripts pass locally.
