#!/usr/bin/env node
/**
 * e2wrap.js — Phase-2 window metrics（以 BOOTTIME 對齊）
 *
 * 既有輸出（維持相容）：
 *   - PHASE2_BOOTTIME_START_NS / PHASE2_BOOTTIME_END_NS / PHASE2_BOOTTIME_MS
 *   - PHASE2_START_NS / PHASE2_END_NS（MONOTONIC）
 *   - PSI_CPU_SOME_PCT / PSI_IO_SOME_PCT / PSI_IO_FULL_PCT / PSI_MEM_SOME_PCT / PSI_MEM_FULL_PCT
 *   - CG_*（pgmajfault / io rbytes / workingset_refault before/after/delta）
 *   - NET_BYTES_BEFORE / NET_BYTES_AFTER（使用 /sys/class/net，預設白名單，排除 lo）
 *
 * 新增（不破壞相容性）：
 *   - E2WRAP_SCHEMA_VER（log schema 版本）
 *   - WRAPPED_CMD（被包裹的命令，方便離線 debug）
 *   - WRAPPED_EXIT_CODE（命令 exit code，方便 summarizer 直接抓，不用靠外部推斷）
 *   - 常用 meta env dump（E2_METHOD / E2_NET_MODE / E2_NPM_CACHE_MODE / E2_NM_MODE / E2_SEED_KEY / E2_LOCK_HASH ...）
 *   - CG_MEMORY_* 仍維持既有輸出規則（若可讀）
 *
 * 注意：
 * - activation / mount-inclusive 建議先由 host-side driver 打點；wrapper 這裡仍以「Phase-2 restore-window」為主。
 */

const fs = require("fs");
const cp = require("child_process");
const path = require("path");

const E2WRAP_SCHEMA_VER = 2;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowMonoNs = () => Number(process.hrtime.bigint());

function readLines(p){
  try { return fs.readFileSync(p,"utf8").split(/\r?\n/); }
  catch { return []; }
}
function safeRead(p){
  try { return fs.readFileSync(p,"utf8"); }
  catch { return null; }
}
function exists(p){
  try { fs.accessSync(p,fs.constants.R_OK); return true; }
  catch { return false; }
}

function nowBootNsStr(){
  try {
    return cp.execFileSync(path.resolve(__dirname,"../bin/boottime_now")).toString().trim();
  } catch {
    return "";
  }
}

function parseCgroupSelfPath(){
  try{
    const lines = readLines("/proc/self/cgroup");
    const rec = lines.find(l => /^0::\//.test(l));
    if(!rec) return null;
    const rel = rec.split("::")[1].trim().replace(/\/+$/,"");
    return path.posix.join("/sys/fs/cgroup", rel);
  }catch{
    return null;
  }
}

function normalizeCgPath(p){
  if(!p) return null;
  if(p.startsWith("/sys/fs/cgroup")) return p.replace(/\/+$/,"");
  return path.posix.join("/sys/fs/cgroup", p.replace(/\/+$/,""));
}

function findLeafWithStat(base, statFile, maxDepth=2){
  try{
    if(exists(path.posix.join(base, statFile))) return base;
    const q=[{dir:base,depth:0}];
    while(q.length){
      const {dir,depth}=q.shift();
      if(depth>=maxDepth) continue;
      let es;
      try{ es=fs.readdirSync(dir,{withFileTypes:true}); }catch{ continue; }
      for(const ent of es){
        if(!ent.isDirectory()) continue;
        const sub=path.posix.join(dir, ent.name);
        const statP=path.posix.join(sub, statFile);
        const procsP=path.posix.join(sub, "cgroup.procs");
        if(exists(statP)){
          try{
            const s = fs.readFileSync(procsP,"utf8").trim();
            if(s.length>0) return sub;
          }catch{}
        }
        q.push({dir:sub, depth:depth+1});
      }
    }
  }catch{}
  return null;
}

async function readIoRbytes(cgPath){
  for(let attempt=0; attempt<5; attempt++){
    let cand=cgPath;
    if(!exists(path.posix.join(cand,"io.stat"))){
      const leaf=findLeafWithStat(cand,"io.stat",2);
      if(leaf) cand=leaf;
    }
    const p=path.posix.join(cand,"io.stat");
    const txt=safeRead(p);
    if(txt!=null){
      let sum=0n;
      for(const line of txt.split(/\r?\n/)){
        const m=line.match(/\brbytes=(\d+)/);
        if(m) sum+=BigInt(m[1]);
      }
      return {ok:1,val:Number(sum),at:cand};
    }
    await sleep(10);
  }
  return {ok:0,why:"no_io_stat"};
}

async function readMemStatKey(cgPath, key){
  for(let attempt=0; attempt<5; attempt++){
    let cand=cgPath;
    if(!exists(path.posix.join(cand,"memory.stat"))){
      const leaf=findLeafWithStat(cand,"memory.stat",2);
      if(leaf) cand=leaf;
    }
    const p=path.posix.join(cand,"memory.stat");
    const txt=safeRead(p);
    if(txt!=null){
      const re=new RegExp(`^\\s*${key}\\s+(\\d+)\\s*$`,"m");
      const m=txt.match(re);
      if(m) return {ok:1,val:Number(m[1]),at:cand};
      return {ok:0,why:`no_${key}`};
    }
    await sleep(10);
  }
  return {ok:0,why:`no_${key}`};
}

async function readPgmaj(cgPath){ return readMemStatKey(cgPath,"pgmajfault"); }
async function readRefault(cgPath){ return readMemStatKey(cgPath,"workingset_refault"); }

function readPsiTotals(kind){
  const s=safeRead(`/proc/pressure/${kind}`);
  if(!s) return {ok:0};
  let someTotal=0n, fullTotal=0n;
  for(const ln of s.split(/\r?\n/)){
    if(/^some /.test(ln)){
      const m=ln.match(/\btotal=(\d+)/); if(m) someTotal=BigInt(m[1]);
    }else if(/^full /.test(ln)){
      const m=ln.match(/\btotal=(\d+)/); if(m) fullTotal=BigInt(m[1]);
    }
  }
  return {ok:1,some:someTotal,full:fullTotal};
}

function pctFromDeltaUs(deltaUs, winUs){
  if(winUs<=0n) return "";
  const v = Number(deltaUs) / Number(winUs) * 100.0;
  return Number.isFinite(v) ? v.toFixed(3) : "";
}

/* ---------- 網路統計（白名單 + 排除 lo） ---------- */
const NIC_ALLOW_RE = process.env.NET_NIC_ALLOW
  ? new RegExp(process.env.NET_NIC_ALLOW)
  : /^(en|eth|ens|eno|wlan|wwan)/; // 預設不含 lo/docker/veth/br-；容器內通常是 eth0，會被納入

function readNetBytesSysfs(){
  const base = "/sys/class/net";
  let rx = 0n, tx = 0n;
  let matched = 0;
  try{
    for(const nic of fs.readdirSync(base)){
      if(nic === "lo") continue;
      if(!NIC_ALLOW_RE.test(nic)) continue;
      const p = path.join(base, nic, "statistics");
      try{
        const r = BigInt(fs.readFileSync(path.join(p,"rx_bytes")));
        const t = BigInt(fs.readFileSync(path.join(p,"tx_bytes")));
        rx += r; tx += t; matched++;
      }catch{}
    }
  }catch{}
  return { total: Number(rx + tx), matched };
}

function resolveCgPath(){
  const fromEnv = process.env.E2_CG_PATH ? normalizeCgPath(process.env.E2_CG_PATH) : null;
  if(fromEnv && exists(fromEnv)) return {path:fromEnv, src:"env"};
  const self = parseCgroupSelfPath();
  if(self && exists(self)) return {path:self, src:"self"};
  return {path:null, src:"none"};
}

function printEnvIfSet(name){
  const v = process.env[name];
  if(v && String(v).length>0) console.log(name+" "+String(v));
}

function parseBytesMaybeMax(s){
  if(!s) return {raw:"", isMax:false, val:null};
  const t = String(s).trim();
  if(t==="max") return {raw:t, isMax:true, val:null};
  const n = Number(t);
  if(Number.isFinite(n) && n>=0) return {raw:t, isMax:false, val:n};
  return {raw:t, isMax:false, val:null};
}

function readCgroupFile(cgPath, file){
  let cand=cgPath;
  const p0=path.posix.join(cand, file);
  let txt=safeRead(p0);
  if(txt!=null) return {ok:1, txt:txt.trim(), at:cand};
  const leaf=findLeafWithStat(cand,"memory.stat",2);
  if(leaf){
    const p1=path.posix.join(leaf, file);
    txt=safeRead(p1);
    if(txt!=null) return {ok:1, txt:txt.trim(), at:leaf};
  }
  return {ok:0, txt:null, at:null};
}

function dumpCommonMeta(){
  // 既有（你已在用）
  printEnvIfSet("RUN_TAG");
  printEnvIfSet("WORKER_ID");
  printEnvIfSet("E2_CONC");
  printEnvIfSet("E2_MEM_PROFILE");
  printEnvIfSet("CG_MEM_MAX_BYTES");

  // 新增：method / fairness meta（driver 可設）
  printEnvIfSet("E2_METHOD");          // e.g., baseline_nocache_online / a2_shared_ro ...
  printEnvIfSet("E2_NET_MODE");        // online|offline
  printEnvIfSet("E2_NPM_CACHE_MODE");  // none|private|shared
  printEnvIfSet("E2_NM_MODE");         // runtime_install|a2_ro|svsafe_ro|b2_subset ...
  printEnvIfSet("E2_SEED_KEY");        // SDL seed key (hash)
  printEnvIfSet("E2_LOCK_HASH");       // lockfile hash
  printEnvIfSet("E2_PROJECT");         // project name if convenient
  printEnvIfSet("E2_VARIANT");         // any variant label
  printEnvIfSet("E2_EXPERIMENT");      // e.g., E2/E5...
  printEnvIfSet("E2_ROUND");           // round index if driver exports
}

async function main(){
  const dash=process.argv.indexOf("--");
  if(dash<0 || dash===process.argv.length-1){
    console.error("Usage: node e2wrap.js -- \"<cmd>\"");
    process.exit(2);
  }
  const cmd=process.argv.slice(dash+1).join(" ").trim();

  // Schema/version marker for robust parsing
  console.log("E2WRAP_SCHEMA_VER "+E2WRAP_SCHEMA_VER);

  // Helpful for offline debugging (summarizer 可選擇忽略)
  console.log("WRAPPED_CMD "+cmd);

  const cgInfo = resolveCgPath();
  const cg0 = cgInfo.path;
  if(!cg0) console.log("CG_PATH_BEFORE ");
  else     console.log("CG_PATH_BEFORE "+cg0);

  dumpCommonMeta();

  if(cg0){
    const maxS = readCgroupFile(cg0, "memory.max");
    const curS = readCgroupFile(cg0, "memory.current");
    const swpS = readCgroupFile(cg0, "memory.swap.current");
    if(maxS.ok){
      const parsed = parseBytesMaybeMax(maxS.txt);
      console.log("CG_MEMORY_MAX "+parsed.raw);
      if(parsed.val!=null) console.log("CG_MEMORY_MAX_BYTES "+parsed.val);
    }
    if(curS.ok){
      const v = Number(curS.txt);
      if(Number.isFinite(v)) console.log("CG_MEMORY_CURRENT_BYTES "+v);
    }
    if(swpS.ok){
      const v = Number(swpS.txt);
      if(Number.isFinite(v)) console.log("CG_SWAP_CURRENT_BYTES "+v);
    }
  }

  const pgB = cg0 ? await readPgmaj(cg0) : {ok:0,why:"no_cgroup"};
  if(pgB.ok) console.log("CG_PGMAJ_BEFORE "+pgB.val);
  console.log("CG_PGMAJ_BEFORE_OK " + (pgB.ok?1:0));
  if(!pgB.ok) console.log("CG_PGMAJ_BEFORE_WHY "+pgB.why);

  const ioB = cg0 ? await readIoRbytes(cg0) : {ok:0,why:"no_cgroup"};
  if(ioB.ok) console.log("CG_IO_RBYTES_BEFORE "+ioB.val);
  console.log("CG_IO_RBYTES_BEFORE_OK " + (ioB.ok?1:0));
  if(!ioB.ok) console.log("CG_IO_RBYTES_BEFORE_WHY "+ioB.why);

  const refB = cg0 ? await readRefault(cg0) : {ok:0,why:"no_cgroup"};
  if(refB.ok) console.log("CG_WORKINGSET_REFAULT_BEFORE "+refB.val);

  const nb0 = readNetBytesSysfs();
  console.log("NET_BYTES_BEFORE "+nb0.total);

  const psiCpuB = readPsiTotals("cpu");
  const psiIoB  = readPsiTotals("io");
  const psiMemB = readPsiTotals("memory");

  const bootStart = nowBootNsStr(); if(bootStart) console.log("PHASE2_BOOTTIME_START_NS "+bootStart);
  console.log("PHASE2_START_NS "+nowMonoNs());

  let status=0;
  try{
    cp.execSync(`bash -lc ${JSON.stringify(cmd)}`, {stdio:"inherit"});
  }catch(e){
    status = (typeof e.status === "number") ? e.status : 1;
  }

  // Always print exit code for stable parsing (in addition to process exit)
  console.log("WRAPPED_EXIT_CODE "+String(status));

  const bootEnd = nowBootNsStr(); if(bootEnd) console.log("PHASE2_BOOTTIME_END_NS "+bootEnd);
  if(bootStart && bootEnd){
    const ms = (BigInt(bootEnd)-BigInt(bootStart))/1000000n;
    console.log("PHASE2_BOOTTIME_MS "+ms.toString());
  }
  console.log("PHASE2_END_NS "+nowMonoNs());

  const cgInfoAfter = resolveCgPath();
  const cg1 = cgInfoAfter.path;
  if(cg1) console.log("CG_PATH_AFTER "+cg1);

  const pgA = cg1 ? await readPgmaj(cg1) : {ok:0,why:"no_cgroup"};
  if(pgA.ok) console.log("CG_PGMAJ_AFTER "+pgA.val);
  console.log("CG_PGMAJ_AFTER_OK " + (pgA.ok?1:0));

  const ioA = cg1 ? await readIoRbytes(cg1) : {ok:0,why:"no_cgroup"};
  if(ioA.ok) console.log("CG_IO_RBYTES_AFTER "+ioA.val);
  console.log("CG_IO_RBYTES_AFTER_OK " + (ioA.ok?1:0));

  const refA = cg1 ? await readRefault(cg1) : {ok:0,why:"no_cgroup"};
  if(refA.ok){
    console.log("CG_WORKINGSET_REFAULT_AFTER "+refA.val);
    if(refB.ok){
      const d = Math.max(0, refA.val - refB.val);
      console.log("CG_WORKINGSET_REFAULT_DELTA "+d);
    }
  }

  const nb1 = readNetBytesSysfs();
  console.log("NET_BYTES_AFTER "+nb1.total);

  const psiCpuA = readPsiTotals("cpu");
  const psiIoA  = readPsiTotals("io");
  const psiMemA = readPsiTotals("memory");

  if(bootStart && bootEnd){
    const winUs = (BigInt(bootEnd)-BigInt(bootStart))/1000n;
    if(psiCpuB.ok && psiCpuA.ok){
      const d = (psiCpuA.some - psiCpuB.some);
      const v = pctFromDeltaUs(d<0n?0n:d, winUs);
      if(v!=="") console.log("PSI_CPU_SOME_PCT "+v);
    }
    if(psiIoB.ok && psiIoA.ok){
      const dS = (psiIoA.some - psiIoB.some); const dF = (psiIoA.full - psiIoB.full);
      const vS = pctFromDeltaUs(dS<0n?0n:dS, winUs); if(vS!=="") console.log("PSI_IO_SOME_PCT "+vS);
      const vF = pctFromDeltaUs(dF<0n?0n:dF, winUs); if(vF!=="") console.log("PSI_IO_FULL_PCT "+vF);
    }
    if(psiMemB.ok && psiMemA.ok){
      const dS = (psiMemA.some - psiMemB.some); const dF = (psiMemA.full - psiMemB.full);
      const vS = pctFromDeltaUs(dS<0n?0n:dS, winUs); if(vS!=="") console.log("PSI_MEM_SOME_PCT "+vS);
      const vF = pctFromDeltaUs(dF<0n?0n:dF, winUs); if(vF!=="") console.log("PSI_MEM_FULL_PCT "+vF);
    }
  }

  process.exit(status);
}

main().catch(e => { console.error("[e2wrap] fatal:", (e&&e.stack)||e); process.exit(1); });
