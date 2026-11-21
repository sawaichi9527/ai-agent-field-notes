# Write-up：sidebar 終端機仍是 Windows 內建 PowerShell — 終端不是外掛 spawn 的，宿主服務才是

- **日期**：2026-11-21（Asia/Taipei）
- **環境**：DSH web GUI（本機），CLI **0.2.2-rc.5**，profile `web`，外掛 `dsh-better-sidebar` **0.32.1**，Windows 10
- **目標**：透過 `dsh-better-sidebar` 开啓的終端機改用便携 PowerShell 7.6.10（取代本机内建 5.1）
- **英文摘要**：[`README.md`](README.md)；**可重用方法**：[playbook 0020](../../playbooks/0020-the-terminal-is-owned-by-the-host-service.md)

## 背景

DSH 的 `pwsh` 工具早已指向便携 PowerShell 7.6.10（`dsh-power-xc` 配置 `pwshPath:
C:/workspace/bin/pwsh7-7.6.10/pwsh.exe`），且已验证 `$PSVersionTable.PSVersion.ToString()` =
`7.6.10`、`utf-8`。但使用者指出：透過 `dsh-better-sidebar` 外掛開起的終端機仍是「windows 10 本机
自带的終端机」（Windows PowerShell 5.1）—— 不是 7.6.10。

## 診斷：外掛没有自有 PTY；終端由宿主服務 spawn

逐包扫描（只读三方插件 + 宿主包 root/lib/src 的 .js/.ts 找 `webTerminals`）得出三件事：

1. **`dsh-better-sidebar` 0.32.1 不自建 PTY。** 底部終端驅動宿主的 `ctx.webTerminals`
   （`@deepseek-ai/dsh-api-terminal-controller` 的 client half）。插件只做结构读
   （`client-terminal.ts`），不 import 宿主包；`dsh.client.inject` 不含 `webTerminals` 時降級。
2. **插件开終端的呼叫不帶 shellPath**：`TerminalView.tsx` 的 `service.view(sessionId, contentId,
   contentId)`。shell 選擇完全落在宿主服務，链条是（源码 `shells.ts` / `client/model.ts` 实测线）：

   ```text
   Config.shell（terminal-controller entry）           ← 最高層
     缺项 → subprocess.terminalEnvironment().defaultShell  （Windows = 内建 PowerShell 5.1）
   新終端（无 shellPath）→ remote.shells(sessionId)      （discoverShells：配置/環境默认排第一）
     → 匹配 localStorage dsh.terminal.shell（path 相等则优先）
     → 否则 shells[0]（= 配置 shell）
   ```

3. **结论：改外掛没用；要覆寫宿主 `terminal-controller` 的 config.shell。** `dsh-web-app` 的
   insert 行只给了 `- id: terminal-controller / name: '@deepseek-ai/dsh-api-terminal-controller'`
   無 config——只有 bundle 层的空行，因此 shell 落在环境默认（内建 5.1）。

## 修复（profile overlay，後層按 id 覆寫整行 config）

`C:\Users\<you>.dsh\profiles\web\cordis.patch.yml` 新增一行：

```yaml
# sidebar / bottom-workbench 終端经宿主 dsh-api-terminal-controller spawn；无配置 shell 时
# 用环境默认（内建 Windows PowerShell 5.1）。以下指向便携 7.6.10。
- id: terminal-controller
  name: "@deepseek-ai/dsh-api-terminal-controller"
  config:
    shell:
      path: C:/workspace/bin/pwsh7-7.6.10/pwsh.exe
      name: PowerShell 7.6.10 (portable, pwsh7 pack)
      args: ["-NoLogo"]
```

- **热载生效，不需重启**：这个 profile 的 `package.json` 有 `patchReload: "live"`（CLI 0.2.2-rc.5），
  合法 config 变更即时生效（此 case 实测）。与 dsh-gitea case 的区別：config **驗証失败** 的 entry
  仍需重启才能重新激活——版本依赖紀錄见下文。
- **独立验证组成**：`dsh --profile web --dump-config`（需在沙盒外/全權運行）顯示
  `terminal-controller` 行被 profile layer 覆寫：`shell.path = C:/workspace/bin/pwsh7-7.6.10/pwsh.exe`、
  `args = ['-NoLogo']`。

## 驗證（使用者实测，新終端）

```
$PSVersionTable.PSVersion.ToString(); (Get-Process -Id $PID).Path
```

输出：

```
7.6.10
C:\workspace\bin\pwsh7-7.6.10\pwsh.exe
```

已開的舊終端进程不会被替换——必须「新建終端」才能看到 7.6.10。

## 附带教训：便携 pwsh pack 的環境毒化

- 便携版 pwsh 的 `PSModulePath` 相對自身位置（`<exe dir>\Modules`）。混合/损坏的 pack 目录會毒化
  宿主（早期 `pwsh7` 是 7.4.6 混合坏目录，整包废弃）。
- 最終 pack：`C:\workspace\bin\pwsh7-7.6.10`（658 檔；zip 109,626,781 B；
  SHA-256 `7D871531806EB1646264E4BBABD9F0C30C23355591BC756BB9909448C29AE166`），自足、干净、不动。

## 版本依赖紀錄（写入 repo 的理由）

- `patchReload: live`：0.2.1-rc.5 不存在（旧手记曾误报）；**0.2.2-rc.5 profile 有此键且合法 config
  热载生效**。
- 已撰寫/已更新的陷阱：`handoff.md` trap #7 补充这条版本的双侧事实（合法 config 热载 vs 失敗 config
  需重启），两类 case 都在这 repo 有证据。
