# 導入简报模板進 ppt-master pack：模板是两个产物，每个消费者有自己的槽

> 環境：Windows 10 Enterprise LTSC 上的 DSH 0.2.2-rc.5 + `dsh-ppt-master-wrapper` + ppt-master
> （external skill，pin **v6.10.0**，source `hugohe3/ppt-master`，tier optional）。模板本身跨 OS
> （opencode 消费侧在 installed skills 下），同步過程涉及一個 LAN forgejo/Gitea mirror。
> 2026-11-23 整理為 field note；材料來自 `opencode-extension-packs/packs/ppt-master/` 実際導入與
> CHANGELOG `2.3.2-docs-6/7/8` 紀錄。
>
> 前置知識：dsh 側任何 ppt-master 路由要先讀 `ppt-master-env`（解释器合入口，不落盤；系统模式
> python 優先、python3 缺失回退 python；實時以 `ppt_master_check_env` 为准），再读 SKILL.md。
>
> 相关方法：[playbook 0024](../../playbooks/0024-dsh-import-a-deck-into-a-ppt-master-pack.md)（导入者
> 的可重用方法）、[playbook 0010](../../playbooks/0010-verify-a-plugin-we-can-call-its-tool.md)
> （「装好≠能用」的 load/config/restart 模型——同一类：注册≠契约）。

---

## 0. 結論（先看這個）

**「模板」在 multi-consumer pack 裡不是一個产物，而是两个：原生 PPTX（契约本体）與 SVG 槽（渲染
载体），兩者的「頁數」是兩種语义，導入別把它们当成同一个计数。**
索引（`decks_index.json` / `<deck_id>.registry.md`）只做 discovery，契约本体留在 round-trip 工作区；
每个消费者有自己的槽與注册方式（opencode = `templates/*.svg` + 统一索引；dsh wrapper = PPTX 拷贝进
自己的 `templates/` + per-deck registry；hermes 槽預留但不創建）。頁面總數 `/N` 在 PowerPoint 无法
存储（無總頁欄位，只有 slidenum），必须用 export patch + 增益集 + 同步工具的组合維持。同步到 LAN
forgejo 用 URL 内嵌 token 的 **http**，不是 https；两种远端都要验证 head SHA。

---

## 1. 時間線

| 日期 | 事件 |
|---|---|
| 導入开始 | FII 2026 三語系（en / zh-CN / zh-TW）簡報模板導入，選定**方案 B 弹性单一源**：一份 canonical 模板 + unified index + per-consumer thin deltas + 保留 `hermes/` 槽 |
| 建 deck | 三語系共享一套视觉系统（1280×720、`canvas_format "ppt169"`、primary `#173367`）；SVG 槽 4 个（`01_cover`/`02_toc`/`03_content`/`04_ending`）、原生 PPTX 5 页（封面/目录/内容×2/结尾）→ **頁數不一致第一次出現** |
| docs-6 | 頁面總數根因記錄：PowerPoint 無總頁欄位、upstream ppt-master v6.10.0 也沒；export patch 寫真實總頁；`tools/sync_page_totals.py`；`addins/FII_PageTotals.ppam` 增益集 |
| docs-7 | 每個 FII deck 加 `dsh/` 槽 + 原生 PPTX + `<deck_id>.registry.md`；`decks_index.json` 與 opencode deck 資料夾 **byte-identical**；多消費者 layout 文档化 |
| docs-8 | `HERMES_SLOT_GUIDE.md`：情境 A（補建 hermes 槽）/情境 B（全新 hermes-only deck）、命名/注册規則、验证 checklist、「不要做」清单 |
| 2026-11-23 | 同步到 LAN forgejo 同名 repo（http + token 嵌 URL），4 分支 head SHA 一一相等驗證；GitHub raw 200 驗證 |
| 2026-11-23 | 整理 field note（本案例 + playbook 0024） |

---

## 2. 取證

| 觀察 | 意義 |
|---|---|
| `decks_index.json` 裡 `page_count: 4`（SVG 槽）⇔ `dsh/*.pptx` 原生 5 页 | 兩種计数各自成立、互不相換 |
| pack 的 `decks_index.json` 與 opencode deck 資料夾 **byte-identical**（格式与 upstream 一致，新增/修改必须同步） | 索引是 discovery artifact，不是契约 |
| dsh 层：PPTX 拷贝进 wrapper `templates/`（按名字/大小、SHA-256 对合）＋ `dsh/<deck_id>.registry.md` | 每个消費者用自己的槽；槽必须带契约本体 |
| retire：bright/dark 移 `decks/_Archive/`，dark 保留 5 SVG + text-slots JSON + `template_execution_manifest.json` + `native_payloads.json.gz` 压缩 payload，**不注册** | 归档保留产物，索引停止指着它 |
| 頁碼 automation 三工具（docs-6）：export patch（写真实总页）＋ `sync_page_totals.py`（`--total --dry-run`）＋ `FII_PageTotals.ppam`（`Auto_Open/PresentationOpen/PresentationNewSlide/PresentationBeforeSave/SlideShowBegin/WindowActivate`，新頁 `3/4 → 4/5`，COM 验证） | `/N` 是运行时算出来的 |
| bare LAN URL push：`TLS connect error: error:0A00010B:SSL routines::wrong version number`；token-in-URL http push：`main -> main` | forgejo LAN 是 http；认证住在 URL |
| 4 分支 head 相等：main + `feature/ppt-master-template` + `feature/pack-manifest-token-usage` + `agent/grill-me-test-triage`（GitHub 与 forgejo mirror 一一相等） | 同步做完 = 兩個远端都回答相同的 head |

---

## 3. "頁數" 是两个语义：SVG 槽 vs PPTX 頁

首版导入時最容易被錯的點，是把「頁数」当成单一数字去对齐：

- `page_count` 是 ppt-master deck 的 **render 语义**：cover/toc/content/ending 4 槽，决定 SVG 模板
  有几个文件、渲染時轮播几张。它不是 PPTX 的頁数。
- PPTX 5 頁是 PowerPoint 的「頁」：封面/目录/内容兩頁/结尾。目录頁與内容複頁讓两者必然不等。

结论：导入時先把两个 artifact 分开命名与审计（SVG 槽数一行、PPTX 页数一行），**绝不**把 PPTX
页数灌进 `page_count`，也不让渲染语义悄悄改掉原生模板。

---

## 4. PowerPoint 沒有總頁欄位：`/N` 是算出来的，不是存起来的

原版导出的页脚 `/N` 出现 `/3`（或漏写总页），根因是 PowerPoint 只有 slidenum（本页号），沒有
总页栏位；upstream ppt-master v6.10.0 也没有。三件工具组合維持 `/N`：

1. **export patch**：导出时写真实总页数；`layout-page-total` shape 标记
   `data-pptx-page-total="true"`；页码 slot `1120 689.9 117 20.53`（top/height 对齐 `/N`）。
2. **增益集 `addins/FII_PageTotals.ppam`**：运行时新增页时 `3/4 → 4/5`（掛
   `Auto_Open/PresentationOpen/PresentationNewSlide/PresentationBeforeSave/SlideShowBegin/WindowActivate`，
   COM 验证）。
3. **CLI `tools/sync_page_totals.py --total --dry-run`**：批量同步页面总数。

注意：上游更新后 export patch 要重套（v6.10.0 也没有总页栏位）。

---

## 5. 消費者分層：契約與索引分离（方案 B 的落点）

导入不是「把 PPTX 丢进一个目录就完事」——多消費者 pack 里模板的落地与注册各有规则：

- **契约本体**：留在 round-trip 工作区
  ```
  python "<skill_dir>/scripts/pptx_to_svg.py" "<deck>.pptx" -o "projects/fii_tpl_<語系>_<YYYYMMDD>" --roundtrip --inheritance-mode both
  ```
  索引只做 discovery——意思是：索引裏有 deck 名，不代表契约在那儿；导入者要先找 round-trip 工作区。
- **opencode 层**：`templates/*.svg` + `images/*.png` + `decks_index.json`（统一索引，byte-identical
  不变式：新增/修改必须同步到 opencode deck 資料夾）。
- **dsh 层**：wrapper 自己的 `templates/` 拷贝原生 PPTX（名字/大小，SHA-256 对合）＋
  `dsh/<deck_id>.registry.md` 注册。
- **保留槽 `hermes/`**：情境 A（既有 deck 補建）/情境 B（全新 hermes-only deck）规则在
  `HERMES_SLOT_GUIDE.md`；不預創，第一个真实消费者触发才建。新消費者要先看命名/注册规则
  （Deck ID `<project>_<YYYY>_<lang>`、语系栏 zh-Hant/zh-Hans/en-US），别平行建立自己的注册流。
- **retire**：移到 `decks/_Archive/` + 停止注册。归档保留产物（manifest + 压缩 payload），索引不再
  指着它——「注册」这件事只发生在索引/registry，删除索引才算真的 retire。

---

## 6. 验证

| 檢查 | 导入前 | 导入后 |
|---|---|---|
| 新增頁的 total | `/3`（或 stale/未写） | 增益集与 export patch 一致（`4/5`），COM 验证 |
| `decks_index.json` 与 opencode deck 資料夾 | 分歧 | byte-identical |
| dsh wrapper 加载该 deck | 无 registry | `dsh/<deck_id>.registry.md` 存在；PPTX 在 wrapper `templates/`；round-trip 产物能打开 |
| forgejo push | `TLS connect error: … wrong version number` | http token URL `main -> main` 接受 |
| GitHub raw | — | `raw.githubusercontent.com` 200，head SHA 与本地一致 |

---

## 7. 被否证／被制止的假設

| 假設 | 判 | 結論 |
|---|---|---|
| 把 PPTX 頁数（5）灌進 `page_count` 就好 | `page_count` 是 SVG 槽语义；改了会拆掉 render | **制止**（兩个计数不同名） |
| 一份統一 index 就能驅動兩個消費者 | dsh wrapper 需要 SKILL_DIR 的 PPTX + registry；opencode 需要 templates + index | **否证**（消費者有自己的落点与注册） |
| 裸 URL 就是 http | forgejo LAN 誤判 https → TLS wrong version | **否证**（http + token-in-URL） |
| 頁數 `/N` 可以在导出时填一次就好 | PowerPoint 無總頁欄位；运行时新增页需要增益集更新 | **否证**（patch + addin + sync 三件） |
| hermes 槽現在就建 | 没有消费者；坑位已文档化 | **制止**（情境 A/B 触发才建） |

---

## 8. 可轉移的教訓

| 教訓 | 為什麼可轉移 |
|---|---|
| **「模板」是两个产物，别合計它们的頁数** | `page_count` 是 SVG 槽语义、PPTX 頁数是 PowerPoint 语义；任何 deck 导入都会撞到這個错位 |
| **契约在工作区，索引只 discovery** | 把索引当成契约就綁死所有消費者到同一 serialisation；保持 discovery 让每個消费者用自己的拷贝 |
| **每个消費者有自己的槽** | opencode 与 dsh wrapper 从不同地方加载同一模板、用不同注册；新消费者（hermes）需要文档化的槽而不是共享一个 |
| **`/N` 是算出来的，不是存起来的** | PowerPoint 无总页栏位；任何 `/N` 导出需要 patch + 运行时增益集才诚实 |
| **retire = 停止注册** | 归档保留产物；索引是唯一「注册」的地方 |
| **LAN mirror 不是 https 默认** | 裸 forgejo URL 会被 http/TLS 猜错；token-in-URL http 才是可行认证 |
| **先读 `ppt-master-env` 再读 SKILL.md** | dsh 侧路由入口是合成对象不落盘；任何 ppt-master 工具调用先确认解释器 |

---

## 9. 未解／下一步

1. **hermes 槽未创建**：情境 A/B 规则已在 `HERMES_SLOT_GUIDE.md`，第一个真实 hermes 消费者触发才建。
2. **export patch 每次上游更新要重套**：v6.10.0 也没有总页栏位，`ppt-master` 升版后 `/N` 会回到
   stale；同步工具 + 增益集仍在，但 patch 是每版审计点。
3. **契约本体留在 round-trip 工作区**：只读索引的人找不到 PPTX——导入入口应是工作区，索引是
   发现层。后续導入者可把「工作区位置」写成 registry 的固定字段，以免契约「看不见」。
