/**
 * FEEDO ERP · 微碧報表自動匯入
 *
 * 每 15 分鐘掃一次 Gmail，找到微碧寄來的「訂單列表.csv」，
 * 解析後寫進 Supabase，然後給信打標籤避免重複處理。
 *
 * 為什麼用 Apps Script：免費、不用改 DNS、不用架伺服器，
 * 而且你舊的 ERP 後端就是這個，你看得懂也改得動。
 *
 * ── 安裝 ────────────────────────────────────────────────
 * 1. script.google.com → 新專案 → 貼上這整份
 * 2. 執行一次 setup()，照提示把四個設定填進「專案設定 → 指令碼屬性」
 * 3. 執行一次 run()，會跳授權視窗，允許它讀 Gmail
 *    ★ 必須用「收到微碧信的那個 Google 帳號」登入 script.google.com，
 *      也就是 feedotea@gmail.com。用別的帳號搜不到信。
 * 4. 排程不用手動設定：run() 第一次執行時會自己建立
 *    「每 15 分鐘」的觸發條件（見 ensureTrigger）。
 *
 * ── 需要的 Supabase 帳號 ─────────────────────────────────
 * 這支程式要用一個真的帳號登入（不是 service key），
 * 因為 erp_pos_import 會檢查 auth.uid() 在不在 erp_staff 裡。
 *
 *   a. Supabase Dashboard → Authentication → Add user
 *      例如 importer@feedomuseum.com，設一組長密碼
 *   b. SQL Editor 執行：
 *      insert into erp_staff (user_id, name, role)
 *      select id, '自動匯入', 'manager' from auth.users
 *      where email = 'importer@feedomuseum.com'
 *      on conflict (user_id) do update set role='manager', active=true;
 *
 * 好處是匯入紀錄的 imported_by 會是這個帳號，追得出來哪幾筆是機器寫的。
 */

// ── 設定：值放在指令碼屬性，不要寫死在程式碼裡 ──────────────
const P = PropertiesService.getScriptProperties();
const CFG = {
  url:      P.getProperty('SUPABASE_URL'),
  anon:     P.getProperty('SUPABASE_ANON'),
  email:    P.getProperty('IMPORTER_EMAIL'),
  password: P.getProperty('IMPORTER_PASSWORD'),
  // 微碧從 noreply@weibyapps.com 寄出，報表區間一結束就寄（例：18:27 收攤 → 18:27 到信）
  query:    P.getProperty('GMAIL_QUERY') || 'from:noreply@weibyapps.com has:attachment newer_than:7d',
  label:    P.getProperty('DONE_LABEL')  || 'ERP已匯入'
};

function setup() {
  Logger.log([
    '到「專案設定 → 指令碼屬性」新增這幾個：',
    '  SUPABASE_URL      https://gezzdwwqxysesxoqhabe.supabase.co',
    '  SUPABASE_ANON     sb_publishable_...',
    '  IMPORTER_EMAIL    importer@feedomuseum.com',
    '  IMPORTER_PASSWORD (那個帳號的密碼)',
    '',
    '選填：',
    '  GMAIL_QUERY       預設 from:noreply@weibyapps.com has:attachment newer_than:7d',
    '  DONE_LABEL        預設 ERP已匯入'
  ].join('\n'));
}

/* 排程自己裝。
   Apps Script 的「新增觸發條件」對話框只能靠人手動點，
   所以改成 run() 第一次執行時自己把排程建起來 —— 按一次 run，
   之後就永遠自動了。 */
function ensureTrigger() {
  const exists = ScriptApp.getProjectTriggers()
    .some(t => t.getHandlerFunction() === 'run');
  if (exists) return false;
  ScriptApp.newTrigger('run').timeBased().everyMinutes(15).create();
  Logger.log('★ 已建立排程：每 15 分鐘自動執行 run()');
  return true;
}

// ── 主流程 ────────────────────────────────────────────────
function run() {
  ['url','anon','email','password'].forEach(k => {
    if (!CFG[k]) throw new Error('指令碼屬性還沒設定完，先執行 setup() 看說明');
  });

  ensureTrigger();   // 沒有排程就順手建一個

  const label = GmailApp.getUserLabelByName(CFG.label)
             || GmailApp.createLabel(CFG.label);

  // 已經處理過的信排除掉，不然每次都會重跑（雖然後端會擋，但白花額度）
  const threads = GmailApp.search(CFG.query + ' -label:' + CFG.label, 0, 20);
  if (!threads.length) { Logger.log('沒有待處理的信'); return; }

  let token = null;
  let done = 0;

  threads.forEach(thread => {
    let handled = false;
    thread.getMessages().forEach(msg => {
      // 同一封信會夾三個檔。訂單列表拿來匯入，營運總表拿來回頭驗算。
      const atts = msg.getAttachments();
      const summary = readSummary(atts);

      atts.forEach(att => {
        const name = att.getName();
        if (!/訂單列表.*\.csv$/i.test(name)) return;   // 其餘兩個檔沒有品項明細

        if (!token) token = signIn();
        try {
          const r = importCsv(token, name, att.getBytes(), att.getDataAsString('UTF-8'), summary);
          Logger.log(name + ' → ' + JSON.stringify(r));
          handled = true;
          if (r && r.ok) done++;
        } catch (err) {
          Logger.log('匯入失敗 ' + name + '：' + err);
          // 失敗就不要打標籤，下次再試
        }
      });
    });
    if (handled) thread.addLabel(label);
  });

  Logger.log('完成，成功匯入 ' + done + ' 份');
}

// ── Supabase ─────────────────────────────────────────────
function signIn() {
  const res = UrlFetchApp.fetch(CFG.url + '/auth/v1/token?grant_type=password', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: CFG.anon },
    payload: JSON.stringify({ email: CFG.email, password: CFG.password }),
    muteHttpExceptions: true
  });
  const body = JSON.parse(res.getContentText());
  if (res.getResponseCode() !== 200 || !body.access_token) {
    throw new Error('Supabase 登入失敗：' + res.getContentText());
  }
  return body.access_token;
}

/* 從同一封信的「營運總表」抓 訂單數 / 營業額，當作獨立的驗算基準。
   格式：
     【訂單統計】
     訂單數,    修改訂單,營業額,訂單付款,    現金,平均訂單金額,
     69,1,"$6,663","$6,663","$6,663",$97,          */
function readSummary(atts) {
  for (let i = 0; i < atts.length; i++) {
    if (!/營運總表.*\.csv$/i.test(atts[i].getName())) continue;
    const rows = parseCSV(atts[i].getDataAsString('UTF-8')).filter(r => r.some(c => c !== ''));
    for (let k = 0; k < rows.length; k++) {
      const h = rows[k];
      if (h[0] !== '訂單數') continue;
      const ci = h.indexOf('營業額');
      const v = rows[k + 1];
      if (!v) break;
      return { orders: num(v[0]), revenue: ci >= 0 ? num(v[ci]) : null };
    }
  }
  return null;
}

function importCsv(token, fileName, bytes, text, summary) {
  const parsed = buildPayload(text);
  if (!parsed.days.length) return { ok: false, message: '這個檔沒有完成的訂單' };

  // 自動匯入最可怕的失敗是「悄悄解析錯」——微碧改個格式，數字就默默少一截。
  // 所以拿同一封信的營運總表對一次，對不起來就不匯，寧可漏也不要錯。
  if (summary) {
    const orders  = parsed.days.reduce((s, d) => s + d.orders, 0);
    const revenue = parsed.days.reduce((s, d) => s + d.revenue, 0);
    if (summary.orders !== null && orders !== summary.orders) {
      throw new Error('訂單數對不上營運總表：解析 ' + orders + '，總表 ' + summary.orders);
    }
    if (summary.revenue !== null && Math.round(revenue) !== Math.round(summary.revenue)) {
      throw new Error('營業額對不上營運總表：解析 ' + revenue + '，總表 ' + summary.revenue);
    }
    Logger.log('對帳通過：' + orders + ' 筆 / $' + revenue);
  }

  const res = UrlFetchApp.fetch(CFG.url + '/rest/v1/rpc/erp_pos_import', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: CFG.anon, Authorization: 'Bearer ' + token },
    payload: JSON.stringify({
      p_id:        Utilities.getUuid(),
      p_file_name: fileName,
      p_file_hash: sha256Hex(bytes),
      p_days:      parsed.days,
      p_rows:      parsed.items,
      p_source:    'weiby'
    }),
    muteHttpExceptions: true
  });
  if (res.getResponseCode() >= 300) throw new Error(res.getContentText());
  return JSON.parse(res.getContentText());
}

function sha256Hex(bytes) {
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, bytes)
    .map(b => ((b < 0 ? b + 256 : b)).toString(16).padStart(2, '0')).join('');
}

// ── 解析（跟 index.html 裡那份邏輯相同）─────────────────────
function parseCSV(text) {
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i+1] === '"') { cell += '"'; i++; } else q = false; }
      else cell += c;
    } else {
      if (c === '"') q = true;
      else if (c === ',') { row.push(cell); cell = ''; }
      else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
      else if (c !== '\r') cell += c;
    }
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.map(r => r.map(x => x.trim()));
}

/* "台東紅烏龍鮮奶茶奶蓋 x 2(1分甜,5分冰,封膜); 四杯袋"
   → [{name, qty, options}, ...]                       */
/* 品名和選項的切法：從字串尾端往回數括號，找出跟最後一個 ')' 配對的 '('。

   不能用 /\(([^()]*)\)$/ ——微碧的折扣是括號裡再包括號：
     伯爵茶(1分甜,5分冰, (-45))
   那個正規表示式遇到巢狀就整個失配，結果「打折的伯爵茶」會變成
   一個獨立品項，不會併進伯爵茶的杯數裡。

   往回數深度就能正確切在最外層：
     伯爵茶(1分甜,5分冰, (-45))  → 伯爵茶 / 1分甜,5分冰, (-45)
     FEEDO T-Shirt (黑-M)( (-30%)) → FEEDO T-Shirt (黑-M) / (-30%)
   後者的 (黑-M) 是品名的一部分，本來就該留著。 */
function splitTrailingParens(str){
  const s = String(str||'').trim();
  if (!s.endsWith(')')) return [s, ''];
  let depth = 0;
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s[i];
    if (c === ')') depth++;
    else if (c === '(') {
      depth--;
      if (depth === 0) return [s.slice(0, i).trim(), s.slice(i + 1, -1).trim()];
    }
  }
  return [s, ''];          // 括號不成對就整串當品名，不要亂切
}

function parseOrderItems(cell) {
  const out = [];
  (cell || '').split(';').forEach(part => {
    part = part.trim(); if (!part) return;
    let options = '';
    const sp = splitTrailingParens(part);
    part = sp[0]; options = sp[1];
    let qty = 1;
    const q = part.match(/\s*[xX×]\s*(\d+)\s*$/);
    if (q) { qty = parseInt(q[1], 10); part = part.slice(0, q.index).trim(); }
    if (part) out.push({ name: part.trim(), qty: qty, options: options });
  });
  return out;
}

function num(v) {
  const n = parseFloat(String(v == null ? '' : v).replace(/[^0-9.\-]/g, ''));
  return isNaN(n) ? 0 : n;
}

function buildPayload(text) {
  const rows = parseCSV(text).filter(r => r.some(c => c !== ''));
  const hdr = rows[0] || [];
  const cNo    = hdr.indexOf('訂單編號');
  const cStat  = hdr.indexOf('訂單狀態');
  const cTotal = hdr.indexOf('總價');
  const cPaid  = hdr.indexOf('付款時間');
  const cItems = hdr.indexOf('訂單項目');
  if (cItems < 0 || cTotal < 0 || cPaid < 0) {
    throw new Error('這不是訂單列表（找不到 訂單項目/總價/付款時間 欄）');
  }

  const dayMap = {}, items = [];
  rows.slice(1).forEach(r => {
    if (cStat >= 0 && r[cStat] && r[cStat] !== '完成') return;   // 取消的不算
    const m = (r[cPaid] || '').match(/(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
    if (!m) return;
    const d = m[1] + '-' + ('0'+m[2]).slice(-2) + '-' + ('0'+m[3]).slice(-2);
    if (!dayMap[d]) dayMap[d] = { date: d, revenue: 0, orders: 0 };
    dayMap[d].revenue += num(r[cTotal]);
    dayMap[d].orders++;
    parseOrderItems(r[cItems]).forEach(it => {
      items.push({ date: d, order_no: cNo >= 0 ? r[cNo] : null,
                   name: it.name, qty: it.qty, options: it.options });
    });
  });

  const days = Object.keys(dayMap).sort().map(k => dayMap[k]);
  return { days: days, items: items };
}

// 裝好之後拿真檔跑一次，Log 出來的數字要跟微碧「營運總表」一樣
function testParse() {
  const threads = GmailApp.search(CFG.query, 0, 1);
  if (!threads.length) { Logger.log('搜尋條件找不到信，先調 GMAIL_QUERY'); return; }
  threads[0].getMessages().forEach(msg => {
    msg.getAttachments().forEach(att => {
      if (!/訂單列表.*\.csv$/i.test(att.getName())) return;
      const p = buildPayload(att.getDataAsString('UTF-8'));
      Logger.log(att.getName());
      Logger.log('每日：' + JSON.stringify(p.days));
      Logger.log('品項列數：' + p.items.length +
                 '　總件數：' + p.items.reduce((s, i) => s + i.qty, 0));
    });
  });
}


/* 一次性工具：把「已匯入」標籤全部拿掉，讓 run() 重新處理所有信。
   解析邏輯改過之後才需要跑這個，平常不要動。
   跑之前記得先在 Supabase 清掉 erp_pos_imports（會連帶清掉明細）。*/
function reimportAll() {
  const label = GmailApp.getUserLabelByName(CFG.label);
  if (!label) { Logger.log('沒有這個標籤，不用清'); return; }
  let n = 0, threads;
  do {
    threads = label.getThreads(0, 100);
    threads.forEach(t => { t.removeLabel(label); n++; });
  } while (threads.length === 100);
  Logger.log('已清除 ' + n + ' 封信的標籤，接下來執行 run() 會重新匯入');
}
