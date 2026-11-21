# RustDesk 開機不會自動啟動、按 "x" 就把服務一起關掉——常駐 tray 模式是 Windows 服務，不是普通應用

> 環境：Windows 10 Enterprise LTSC (build 17763) 本機 · RustDesk Windows 版 · 2026-11-22 (Asia/Taipei)

## 0 結論

兩個症狀的根源不是"安裝壞了"也不是"版本問題"，而是：**RustDesk 一直以普通應用模式運行，
Windows 服務从未安裝**。普通應用模式沒有 tray 进程，按 X 就是把整組进程關掉、不留常駐、开机也不自動。
修法是安裝服務模式（`RustDesk.exe --install-service`）：Windows 服務隨开机自動啟動，
`--tray` 进程常駐，按 X 只關 UI 而不關服務。

## 1 症狀

- 开机後 RustDesk 不會自動啟動，需要手动打開。
- 手动啟動後，右上角的 "x" 把"主程序 + UI"整組關掉，而不是縮到右下角 tray 图标持續運行。

## 2 分辨：兩種模式

| 模式 | 进程 | 按 X 的結果 | 开机 |
|---|---|---|---|
| 普通應用模式 | 主进程 + `--cm` UI 进程 | 整組關閉、無 tray | 不自動 |
| 服務模式 | Windows 服務 "RustDesk Service"（`--service`）+ `--tray` 进程 | UI 關閉、tray 繼續運行 | 自動（登入前/後均可連） |

服務模式的 Windows 服務由 LocalSystem 帳戶运行、AUTO_START，所以开机自動、連登入畫面都可連。
普通應用模式只是一個 GUI 程序，X 就是結束——與"連服務一起關閉"的观感一致。

## 3 關鍵證據（前置）

2026-11-13 的 update log 已出現

```
"No tray process found. Try to restore the main window process..."
```

——这台機器上 tray 进程不存在，更新流程才会要求把主視窗拉回来。tray 缺位是舊病，不是新症狀。

## 4 修法

在 PowerShell（非 agent 沙箱）執行：

```powershell
& "C:\Program Files\RustDesk\RustDesk.exe" --install-service -wait -Verbose
```

GUI 型程式沒有 exit code；服务注册約 22 s。**立刻查 `Get-Service` 看不到服務**，要等注册完成再查。

## 5 安裝後確認

- `Get-Service RustDesk` → `Running`、DisplayName "RustDesk Service"（注册後才出現）。
- `sc.exe qc RustDesk`（权威配置视图）：
  - `TYPE 10 WIN32_OWN_PROCESS`
  - `START_TYPE 2 AUTO_START`
  - `BINARY_PATH_NAME "C:\Program Files\RustDesk\RustDesk.exe" --service`
  - `SERVICE_START_NAME LocalSystem`
- 进程：主进程（无 args）+ `--tray` 进程共存——"X 不再把整組關掉"的證明。
- install log `C:\Users\<you>\AppData\Roaming\RustDesk\log\install-service\RustDesk_rCURRENT.log`：

```
INFO [src\core_main.rs:374]  start --install-service
INFO [src\platform\windows.rs:3444] Installing service...
DEBUG [src\platform\windows.rs:4111] Spawn new window
```

## 6 上線注意

- 服务注册耗时（~22 s）；"查了没出现"只是查得太早，不是失敗。用 `sc.exe qc` 驗證，不只看窗口。
- "开机不会自动启动"和"X 把服务一起关了"是**同一个缺失组件**（没注册服务 + 没 tray），不是两个 bug。
- 無人值守連線還需要固定密碼等設定；本次任务完成了服务安装，連線行为未測（無第二台 peer 驗證）。

## 7 指令備忘

```
& RustDesk.exe --install-service -wait -Verbose   # 安装 Windows 服务（GUI，无 exit code）
Get-Service RustDesk                               # 状态（注册约 22 s，别立刻查）
sc.exe qc RustDesk                                 # 服务配置：自动启动 / LocalSystem / --service
```

## 8 上游連結

- RustDesk 官方「無人值守存取」中文指南（固定密码 + 以服务方式执行 + 开机启动）：
  https://rustdesk.com/zh-tw/blog/rustdesk-unattended-access-setup-zh-tw/
- GitHub Discussion #6088（Run as Service only）：
  https://github.com/rustdesk/rustdesk/discussions/6088
- CoSci 博客（RustDesk Service 自动启动 / 关闭时停服务的問題）：
  https://cosci.de/de/programme-de/rustdesk-vermittlungsdienst-startet-nicht/
- RustDesk GitHub 上相似的回報（服務/啟動/tray 相關）：#14019 · #9108 · #9286 · #9284 · #6620
