Workload Reduction for Dependency Restoration Latency

本 repository 對應碩士論文實作與實驗工具鏈，研究目標是在 containerized multi-tenant、high concurrency 與 tight memory budgets 的 CI/runner 環境中，針對「dependency expansion / initialization」造成的大量 file-system metadata I/O，採取 Work Reduction 方向：不追求讓單筆 I/O 更快，而是減少任務線上路徑需要進行的檔案系統操作量，從而降低 page cache thrashing 並抑制 tail latency。



本研究提出兩個互補策略：

Shared Dependency Layer (SDL)：離線 prebuild 完整 dependency tree，線上以 static read-only mapping（例如 read-only bind-mount）提供，避免重複 file creation 與 metadata overhead。



Necessary Dependency Subset (NDS)：以 startup-verification tasks 的 execution traces 離線萃取 minimal required files，線上只 materialize 子集以縮小 metadata footprint。



在最嚴苛（high concurrency + memory pressure）情境下，可達到 orders-of-magnitude 改善，將 execution time 由 tens of seconds 降至 seconds。

Repository 結構

bin/：主要 driver 與實驗腳本（matrix sweep、preflight、setup/teardown、summarize 等）

e2_tools/：wrapper（例如 e2wrap.js），負責統一量測邊界與輸出格式

plt/：繪圖與產圖腳本/成品（如 latency stacked bars、CG_IO_RBYTES 等）

VERSION.md：版本/實驗註記

以下資料夾為實驗產物、cache、或大型資料，預設不進 Git（請見 .gitignore）：

work/, result/, locks/, frontier_poc/, projects/, a2_ro/, shared_deps/, npm-cache* 等

量測定義與指標

本專案以 Dependency Restoration Window 作為各方法可比對的共同量測邊界：

時間窗為 [t_start, t_end]

wrapper 在執行 restore command 前做 pre-sample（讀取 major page fault 與 io.stat），並以 boottime_now() 記錄 t_start

restore 完成後做 post-sample，再次記錄 t_end 並重讀指標

Latency = t_end - t_start；其他系統行為指標以 post - pre 的差分計算，並由 wrapper 寫入實驗紀錄

時間量測使用 CLOCK_BOOTTIME 以避免 wall-clock/NTP 影響，確保高併行長時間實驗一致性


需求環境（建議）

Linux（支援 cgroup v2 與容器 runtime）

Bash、Python 3（用於 log 彙整與 plotting）

Node.js（用於 wrapper：e2_tools/e2wrap.js）

需要可讀取 io.stat、major page faults 等系統資訊（依你的實驗腳本設計）

Quick Start

先確認目前 repo 只包含「可公開/可重現」的程式碼與小型產物（已透過 .gitignore 排除大型 logs/data）：

git status
git check-ignore -v work/* result/* frontier_poc/* npm-cache* | head


進行基本環境檢查（依你的腳本命名，通常是 preflight）：

./bin/e2_preflight.sh


跑單次或小規模 smoke（避免一開始就 sweep 全矩陣）：

./bin/e2_matrix_smoke.sh


跑矩陣 sweep（會依 conc/mem/workload 等設定批次執行）：

./bin/e2_matrix_sweep.sh


彙整最新結果：

./bin/e2_summary_latest.sh


Plotting（產生論文圖）

plt/ 內包含繪圖腳本與產圖結果。流程如下：

先確保 result.csv 或彙整後的輸入檔已經在你預期的位置（通常在 result/ 或某個 logs 彙整目錄）。

執行 plt/ 內對應腳本（例如 latency/IO 的圖）：

python3 plt/time.py
python3 plt/IO.py

資料與可重現性政策（重要）

本 repo 只追蹤 driver/tools/plot scripts 與少量必要資源

work/, result/, frontier_poc/, projects/, npm-cache* 等視為 可再生或大型資料，不納入版本控管

若需要對外共享結果，建議採用：

上傳「彙整後的小型 result.csv（去識別/去敏感）」或

以 GitHub Release / external storage 提供資料集，repo 只保留產生流程
