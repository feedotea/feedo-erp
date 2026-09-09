# FEEDO ERP · 後端部署

後端從 Google Apps Script 換成 Supabase（專案 `gezzdwwqxysesxoqhabe`，與 feedo-claim 共用）。

## 一次性建置

在 Supabase Dashboard → SQL Editor，**依序**執行：

| 順序 | 檔案 | 做什麼 |
|---|---|---|
| 1 | `01_schema.sql` | 建表、索引、衍生檢視 |
| 2 | `02_rpc.sql` | 建立 13 個 RPC |
| 3 | `03_security.sql` | RLS deny-all，只開放 RPC 給登入者 |
| 4 | `04_seed.sql` | 匯入 16 個品項主檔 |
| 5 | `05_pos_import.sql` | 微碧 POS 報表匯入（表 + RPC + 權限） |
| 6 | `06_analytics.sql` | 營運分析（`erp_analytics`，只讀，店長限定） |
| 7 | `07_ordering.sql` | 叫貨改用到貨天數（`lead_days`/`cover_days`、在途量） |
| 8 | `08_orders.sql` | 逐筆訂單（時段分析、單筆訂單分析） |
| 9 | `09_labor.sql` | 設定表 `erp_settings` + 逐時段逐星期出杯量（人力估算） |

順序不能顛倒（03 要先有 01、02 建立的物件才收得掉權限）。

## 建立第一個帳號

1. Dashboard → Authentication → Users → **Add user**，填 email 和密碼。
2. 回 SQL Editor 執行（把 email 換成你剛建的）：

```sql
insert into erp_staff (user_id, name, role)
select id, '你的名字', 'owner' from auth.users where email = 'you@example.com'
on conflict (user_id) do update set role = 'owner', active = true;
```

`role` 三種：`staff`（一般店員）、`manager`、`owner`。
改品項主檔（新增/編輯/刪除品項）需要 manager 以上，其餘操作 staff 就夠。

之後每加一個店員，就重複這兩步。**沒有列在 `erp_staff` 的帳號登入後會被擋下並自動登出。**

## 建立庫存起帳點

`04_seed.sql` 只寫主檔，**不寫任何庫存數字**。

庫存是異動加總出來的，所以第一次上線要實際盤一次：
App →「庫存」頁 → 盤點 → 逐項填實際數量 → 確認。
系統會寫出第一批 `stocktake` 異動，那就是起帳點。

在這之前所有品項庫存都是 0，叫貨頁會把全部品項列為「該叫貨」，屬正常現象。

## 資料模型重點

- **`erp_stock_moves` 是庫存唯一真相**。沒有 `bal` 欄位，餘額 = `sum(qty_delta)`。
  盤點不覆蓋數字，而是寫一筆調整，歷史完整保留。
- **每筆寫入帶前端產生的 UUID**，`on conflict do nothing`。
  斷線重送不會變成兩筆，這是離線佇列能安全重試的前提。
- **`avg_per_day` 會自己長出來**。累積 14 天以上實際紀錄後，
  自動改用近 28 天真實耗用取代 `avg_per_day_manual`（見 `erp_v_items`）。
- **時區一律走 `erp_today()`**（Asia/Taipei）。直接用 `now()` 會讓台灣早上 8 點前
  記的帳掉到前一天。

## 前端

`index.html` 單檔，GitHub Pages 部署到 erp.feedomuseum.com。
需要改的設定只有檔案開頭的 `SUPABASE_URL` / `SUPABASE_ANON`。

anon key 是公開的沒關係 —— 所有表都是 RLS deny-all 且已 revoke，
PostgREST 看不到它們，唯一入口是 `erp_*` function，而 function 自己會查 `erp_staff`。

## 權限分界：店長 vs 店員

`erp_staff.role` 三種：`staff` / `manager` / `owner`（manager 和 owner 目前權限相同）。

| 功能 | 店員 | 店長 |
|---|:--:|:--:|
| 煮茶登記（含當日營收輸入） | ✅ | ✅ |
| 記一筆（進貨 / 用量） | ✅ | ✅ |
| 記損耗 / 報廢 | ✅ | ✅ |
| 叫貨、複製訊息、標記已叫 | ✅ | ✅ |
| 看庫存、可撐幾天 | ✅ | ✅ |
| 庫存總值（成本資訊） | ❌ | ✅ |
| 月度盤點 | ❌ | ✅ |
| 品項主檔（新增 / 編輯 / 刪除） | ❌ | ✅ |
| 帳務模式整區（營收、記開銷、報表、月結） | ❌ | ✅ |
| 刪除任何紀錄 | ❌ | ✅ |

設計理由：
- **店員做得到「發生了什麼」，做不到「這值多少錢」。** 現場異動全開，成本與損益全關。
- **盤點是店長的。** 盤點會直接改庫存數字，是最容易把短少抹平的動作。
- **店員的 bootstrap 根本不會收到 expenses / revenue。** 資料不送出去，不是送出去再靠前端不顯示。

前端只是把按鈕藏起來（`applyRole()`），**真正的線畫在 `erp_require_manager()`**。
店員開 devtools 直接呼叫 `erp_add_expense` 一樣會被擋，錯誤是「這個功能限店長使用」。


## 微碧 POS 匯入

不買微碧的「ERP 串接」加購模組（$500/月）。用匯出檔匯入，零成本。

### 只用「訂單列表.csv」

微碧匯出會寄三個檔，**只有訂單列表能用**：

| 檔案 | 有什麼 | 能不能用 |
|---|---|---|
| **訂單列表** | 日期、總價、品項、數量、**選項** | ✅ |
| 營運總表 | 品項數量（一欄一個品項的轉置版面），無選項 | ❌ |
| 交易列表 | 只有付款金額 | ❌ |

`訂單項目` 欄長這樣，整格被引號包住：

```
"台東紅烏龍鮮奶茶奶蓋 x 2(1分甜,5分冰,封膜); 四杯袋"
```

品項間用 `; ` 隔開、` x N` 是數量、括號內是選項。
**選項裡的「環保杯」「封膜」之後要拿來精算包材** ——
賣 100 杯但有 2 杯客人自帶環保杯，就只該扣 98 個紙杯。

### 驗證

用 2026/09/07 的真實檔跑過，跟微碧自己的營運總表逐項對帳：

| | 解析結果 | 微碧總表 |
|---|---|---|
| 完成訂單 | 69 | 69 ✓ |
| 營業額 | $6,663 | $6,663 ✓ |
| 奶蓋類 / 純茶類 / 鮮奶茶類 / 袋子 | 35 / 33 / 32 / 5 | 全部一致 ✓ |

26 個品項的數量全中。匯入畫面會顯示訂單數和營業額，**跟營運總表對一眼就知道有沒有讀錯**。

### 手動匯入

ERP → 帳務 → 營收 →「⬆ 匯入微碧報表」→ 選訂單列表 CSV → 確認。

- 明細寫進 `erp_pos_sales`（含 order_no 和 options）
- 那幾天的 `erp_revenue` 用訂單總價加總覆蓋，手 key 的值以 POS 為準
- 訂單狀態不是「完成」的（取消單）不計
- 同一份檔案匯第二次會被 `file_hash` 擋下
- 同一天重匯會整批換掉，不疊加

### 自動匯入（Gmail + Apps Script）

`automation/weiby-gmail-import.gs`。每 15 分鐘掃信箱、抓訂單列表附件、
解析後寫進 Supabase、打標籤避免重複。免費，不用改 DNS 也不用架伺服器。

要先開一個專用的 Supabase 帳號（例如 `importer@feedomuseum.com`）
並加進 `erp_staff` 當 manager —— 因為 `erp_pos_import` 會檢查 `auth.uid()`，
service key 沒有身分，過不了那道關。這樣匯入紀錄的 `imported_by`
會是那個帳號，追得出來哪幾筆是機器寫的。

**已確認的信件細節**（從實際收到的信看的）：

| | |
|---|---|
| 寄件人 | `noreply@weibyapps.com` |
| 收件信箱 | `feedotea@gmail.com` |
| 寄出時間 | 報表區間結束當下（18:27 收攤 → 18:27 到信） |
| 附件 | 一封信夾三個 CSV（訂單列表 / 營運總表 / 交易列表） |

所以預設搜尋條件是 `from:noreply@weibyapps.com has:attachment newer_than:7d`。

⚠️ **必須用 `feedotea@gmail.com` 登入 script.google.com**，用別的帳號搜不到信。

**自動對帳**：一封信裡三個檔都在，所以匯入前會拿同一封信的「營運總表」
回頭驗算 —— 解析出的訂單數和營業額要跟總表一致，對不上就**不匯入**、
不打標籤、記進 Log，下次再試。

自動匯入最可怕的失敗是「悄悄解析錯」：微碧改個格式，數字默默少一截，
而你要到月底對帳才發現。有這道檢查就寧可漏也不會錯。
（已用 2026/09/07 的真實檔驗過：解析 69 筆 / $6,663，總表 69 筆 / $6,663，PASS。）

安裝步驟寫在 .gs 檔案開頭。裝好先跑 `testParse()`，
Log 出來的數字要跟營運總表一樣，再掛定時觸發器。

### 還沒做

`erp_pos_item_map`（微碧品項名 → ERP 品項）表建好了，但還沒有對應介面。
26 個品項名已經知道長什麼樣了（`台東紅烏龍鮮奶茶奶蓋`、`四杯袋`…），
下一步就是把它們對到 ERP 品項，然後才能做配方扣料。

## 進貨成本與毛利

**進貨時可以填「這批多少錢」**（選填）。填了就會用**移動平均**更新 `erp_items.cost`：

```
新成本 = (舊庫存 × 舊成本 + 進貨量 × 進貨單價) / 總量
```

直接覆蓋成最新價會讓舊庫存的成本憑空跳動，毛利就不準了。

月結拿不到價格就留空，後端不會動成本。每一筆的當時單價都留在
`erp_stock_moves.unit_cost` —— **不記下來，成本歷史永遠補不回來。**

⚠️ `erp_log_move` 因此多了 `p_unit_cost` 參數，簽章變了。
`create or replace` 遇到不同簽章是「多一個多載」而不是取代，所以
02 開頭有 `drop function if exists erp_log_move(uuid,text,text,numeric,text,date)`。
不砍掉的話 PostgREST 可能挑到舊的那個，單價會被默默丟掉。

離線佇列重送時，`insert ... on conflict do nothing` 不會再寫一筆，
成本也不能再平均一次 —— 靠 `get diagnostics ins = row_count` 擋住。

### 報表的物料成本

`renderReport` 的「物料成本」現在來自 `erp_month_report` 的 `cogs`，
也就是**當月實際耗用的料 × 成本**（從 `erp_stock_moves` 算）。

以前是拿「當月付給廠商的現金」當成本，那是錯的：茶葉月結，
7 月付的是 6 月的貨，兩個不同月份相減出來的毛利沒有意義。
現金流另外列成「本月付給廠商」，標明它不是成本。
