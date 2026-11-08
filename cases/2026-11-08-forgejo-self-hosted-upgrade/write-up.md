# 案例：透過 SSH 把自架 ForgeJo 升到最新版——沒出錯，但差點沒有備份

**服務：** ForgeJo 16.0.4 → 17.0.1（`codeberg.org/forgejo/forgejo`），單一 `docker-compose` 服務，
資料走 host bind-mount。**存取：** SSH 帳號密碼（一個沒有 sudo 的服務帳號）。**日期：** 2026-11-08

## 背景

遠端 `<LAN-IP>` 上跑一個自架 ForgeJo，是單一 `docker-compose` 服務，資料卷 bind-mount 到 host。
任務很單純：「升到最新版 image」。做到備份那一步才發現——備份該寫的位置，SSH 帳號寫不進去；
而資料裡某個子目錄，SSH 帳號又讀不到。

## 動手前先量測（沒改狀態）

先確認架構，不要假設路徑：

```bash
# 目前 image + 容器
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

# 資料架構：看 bind-mount 掛在哪
docker inspect forgejo   # 記下 host 資料目錄

# DB 型別：讀 app.ini（決定備份要不要另外處理 postgres）
grep DB_TYPE /data/forgejo/data/gitea/conf/app.ini      # 結果：DB_TYPE = sqlite3

# 磁碟餘裕
df -h /data
```

摸出來的重點：

- 單一服務 `forgejo`，image 寫死 `16.0.4`，port `3000`（web）+ `2222`→`22`（ssh）。
- 資料卷是 `/data/forgejo/data:/data`，DB 是 **SQLite**（`gitea.db`），沒有外部 postgres——整個
  服務就活在這個資料夾裡。
- 真正的 git 倉庫在 `git/repositories/`（子目錄，不是預設的 `git/repos`）；各用戶目錄是**符號連結**，
  指向 `/data/git/repositories/<user>`——而那個路徑根本不存在。六個連結在動手前就已經壞了。
- `/data/forgejo` 歸 root 所有（SSH 帳號寫不進去）；但值得備份的 `git/` 歸 SSH 帳號所有。

## 陷阱一：備份位置是權限地雷

想直接 tar 整個資料卷，但有兩個坑：

1. **寫不出去**：直接寫 `/data/forgejo/backup-*.tar.gz` 會失敗，因為 `/data/forgejo` 是 root 擁有、
   SSH 帳號無寫入權。要写到 SSH 帳號真正寫得去的地方（這台是 `~/`）。
2. **讀不進去**：live tar 撞到根目錄 `data/ssh`（`700`、root 擁有），SSH 帳號讀不到。`tar` 因此
   exit 2，看起來像「沒備份到」。

解法：把輸出導到寫得去的路徑，並用 `--exclude` 跳過那個讀不到的子樹：

```bash
# 寫到 SSH 帳號寫得去的 ~/，排除 data/ssh（host key，可重生成）
tar --exclude='data/ssh' -czf ~/backup-forgejo-$(date +%Y%m%d-%H%M%S).tar.gz -C /data/forgejo data
```

**關鍵：不要相信 exit code。** tar 因單一讀不到的檔 exit 2，但 archive 可能仍然有效。一定要 explicit
驗完整性，並 grep 確認關鍵檔在裡面：

```bash
tar -tzf ~/backup-forgejo-*.tar.gz >/dev/null && echo OK || echo CORRUPT          # 完整性
tar -tzf ~/backup-forgejo-*.tar.gz | grep -c 'gitea/gitea.db'                      # DB 在嗎
tar -tzf ~/backup-forgejo-*.tar.gz | grep -c 'conf/app.ini'                        # config 在嗎
tar -tzf ~/backup-forgejo-*.tar.gz | grep -c '/git/repositories/'                  # repo 在嗎
```

這台驗出來：archive 816 MB、完整性 OK、31 個 repo（469 MB）、`gitea.db`、`app.ini` 都在。
備沒產生或驗證失敗 = 沒有備份，修好重做，不要往上走。

## 陷阱二：計畫要匹配真實架構

各用戶目錄是符號連結，指向已刪除的 `/data/git/...`。動手前確認真實路徑是
`/data/forgejo/data/git/repositories/<user>`，於是把每個壞連結重建到真實路徑（`<user>` 是倉庫
擁有者名稱，這台有六個）：

```bash
cd /data/forgejo/data/git
for u in <user-A> <user-B> <user-C> <user-D> <user-E> <user-F>; do
  rm -f "$u"
  ln -s "/data/forgejo/data/git/repositories/$u" "$u"
done
```

驗全部解析、且透過連結能數到倉庫（用 `-L` 跟隨連結遞迴數 `HEAD`）：

```bash
find -L <user-A> -name HEAD | wc -l      # 每個用戶下實際的 .git 數量
```

## 套用（最小停頓）

```bash
# 1. 改 compose 的 image tag（16.0.4 → 17.0，自動跟 17.0.Y patch；要釘死就寫 17.0.1）
sed -i 's|codeberg.org/forgejo/forgejo:16.0.4|codeberg.org/forgejo/forgejo:17.0|' \
     /home/sqa/docker-stack/forgejo/docker-compose.yml

# 2. 先 pull（不停機；舊容器還在時就拉好）
cd /home/sqa/docker-stack/forgejo && docker compose pull forgejo

# 3. 重建（bind-mount 資料保留；容器重啟 → 短停頓）。首次啟動會自動跑 DB schema 遷移
docker compose up -d forgejo
```

## 事後驗證

```bash
curl -sS http://<LAN-IP>:3000/api/v1/version      # 結果：{"version":"17.0.1+gitea-1.22.0"}
docker ps --filter name=forgejo --format "{{.Names}} {{.Image}} {{.Status}}"   # Up 在新 image
curl -sS http://<LAN-IP>:3000/ -o /dev/null -w "HTTP %{http_code}\n"           # HTTP 200
docker compose logs --tail 25 forgejo | grep -iE "error|fail|migrat|listen"    # migration 成功、listen 行
```

結果：v17 的 DB migration 全部順利、web HTTP 200、服務 Up 在 `17.0`。六個符號連結全部解析，
reachable repo 數不變（31）。

## 收尾

體積檢查：volume 內那個 9/11 的舊 dump（`forgejo-dump-*.zip`, 252 MB）已無用，刪掉省空間：

```bash
rm -f /data/forgejo/data/gitea/forgejo-dump-20260911-223935.zip
```

`/data/forgejo/data` 從 828 MB → 587 MB（省 ~241 MB）；`/data` 剩 434G。備份檔仍在
`~/backup-forgejo-20261108-122526.tar.gz`（816 MB，含 31 repo + DB + config）。

## 這次最重要的兩條教訓

1. **備份寫到哪、讀不到什麼，先摸再說。** 別假設路徑 writable/readable；先找到 SSH 帳號真正
   寫得去的地方再動。tar exit 2 不等於「沒備份」，`tar -tzf` + grep 關鍵檔才是真相。
   （可复用：[playbook 0008](../playbooks/0008-maintain-self-hosted-docker-over-ssh.md)）
2. **大版本跳躍有 breaking changes。** v17 改了渲染文檔裡絕對連結的基準（repo 根取代 instance
   根）、棄用 Action run webhook（要手動移到 workflow run events）。升級前讀它們、檢查有没有
   相依的 webhook 或深連結文件，並向使用者標出來。這是「改狀態」操作，依序呈現順序與風險，等
   明確確認再執行。
