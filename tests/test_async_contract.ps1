[CmdletBinding()]
param(
    [switch]$SkipCargo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$script:Failures = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
    else {
        Write-Host "FAIL: $Message" -ForegroundColor Red
        $script:Failures++
    }
}

function Read-ProjectFile([string]$RelativePath) {
    $path = Join-Path $projectRoot $RelativePath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "$RelativePath exists"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    Get-Content -LiteralPath $path -Raw
}

$protocol = Read-ProjectFile 'docs\ASYNC_PROTOCOL.md'
$architecture = Read-ProjectFile 'docs\ARCHITECTURE.md'
$asyncLua = Read-ProjectFile 'lua\rime_bilingual_async.lua'
$asyncLuaCode = $asyncLua -replace '(?m)--.*$', ''
$filterLua = Read-ProjectFile 'lua\rime_bilingual.lua'
$filterLuaCode = $filterLua -replace '(?m)--.*$', ''
$schema = Read-ProjectFile 'rime_ice.custom.yaml'
$bridge = Read-ProjectFile 'bridge\src\lib.rs'
$helper = Read-ProjectFile 'helper\src\lib.rs'
$helperMain = Read-ProjectFile 'helper\src\main.rs'
$installer = Read-ProjectFile 'scripts\install.ps1'
$uninstaller = Read-ProjectFile 'scripts\uninstall.ps1'
$weaselWakePatch = Read-ProjectFile 'weasel\patches\0001-rime-bilingual-ready-refresh.patch'
$weaselNoMfcPatch = Read-ProjectFile 'weasel\patches\0002-winres-no-mfc.patch'

# Cross-module constants and deployment payload must agree with the frozen V0.3 contract.
Assert-True ($protocol -match 'native pending ring \| 8 batches') 'protocol fixes the pending ring at 8 batches'
Assert-True ($protocol -match 'native completion ring \| 32 batches') 'protocol fixes the completion ring at 32 batches'
Assert-True ($protocol -match 'completion retention \| 30') 'protocol fixes completion retention at 30 seconds'
Assert-True ($asyncLua -match 'local PROTOCOL_VERSION = 2') 'Lua configures protocol v2'
Assert-True ($asyncLua -match 'queue_capacity = 8') 'Lua queue capacity matches the protocol'
Assert-True ($asyncLua -match 'completion_capacity = 32') 'Lua completion capacity matches the protocol'
Assert-True ($schema -match 'request_timeout_ms:\s*3000') 'schema provides the bounded default worker timeout'
Assert-True ($installer -match '\$productVersion\s*=\s*''0\.3''') 'installer publishes product version 0.3'
Assert-True ($installer -match '\$manifestVersion\s*=\s*4') 'installer publishes manifest schema 4'
Assert-True ($installer -match "'lua\\rime_bilingual_async\.lua'") 'installer deploys the async Lua module required by the filter'
Assert-True ($installer -match "'rime-bilingual\\native\\rime_bilingual_bridge\.dll'") 'installer deploys the native bridge'
Assert-True ($uninstaller -match "'lua\\rime_bilingual_async\.lua'") 'uninstaller accounts for the async Lua module'
Assert-True ($uninstaller -match "'rime-bilingual\\native\\rime_bilingual_bridge\.dll'") 'uninstaller accounts for the native bridge'

# Rime callbacks may only use memory and the bounded native API.
Assert-True ($asyncLua -match 'package\.loadlib') 'bridge is loaded explicitly at component init'
Assert-True ($asyncLua -match '/rime-bilingual/native/rime_bilingual_bridge\.dll') 'bridge load path is under the managed Rime data directory'
Assert-True ($asyncLua -match 'pcall\(bridge\.configure') 'native configure failure is isolated'
Assert-True ($asyncLua -match 'bridge_call\(state, "try_submit"') 'Lua submits through the bounded bridge API'
Assert-True ($asyncLua -match 'bridge_call\(state, "try_poll"') 'Lua polls through the bounded bridge API'
Assert-True ($asyncLuaCode -notmatch 'menu:prepare\(') 'Lua async callbacks never force Menu preparation'
Assert-True ($filterLuaCode -notmatch 'segment\.menu|menu:prepare\(') 'candidate filter never re-enters the active Rime Menu'
Assert-True ($asyncLua -match 'update_notifier' -and $asyncLua -match 'menu:candidate_count\(\)' -and $asyncLua -match 'menu:get_candidate_at\(absolute_index\)') 'page navigation observes only already materialized destination candidates'
Assert-True ($asyncLua -match 'state\.composition_input ~= input') 'page navigation callback is isolated from normal input edits'
Assert-True ($filterLua -match 'target_page_start = math\.floor\(selected_index / page_size\) \* page_size') 'candidate filter targets the currently selected visible page'
Assert-True ($filterLua -match 'local buffered = \{\}' -and $filterLua -match 'finish_page\(\)' -and $filterLua -match 'yield\(candidate\)') 'candidate filter batches one selected page while preserving the upstream lazy-yield contract'
Assert-True ($filterLua -match 'local submitted = false' -and $filterLua -match 'absolute_index < target_page_start \+ page_size') 'prefetched later pages cannot replace the visible-page async state'
Assert-True ($filterLua -match 'is_vertical_layout\(user_data_dir, warn\)' -and $filterLua -match 'requested_enabled and env\.bilingual_vertical_layout') 'bilingual annotations are enabled only for a compiled vertical Weasel layout'
Assert-True ($asyncLua -match 'if options\.enabled == false then' -and $asyncLua -match 'state\.enabled = false') 'horizontal layout disables async callbacks before page tracking begins'
Assert-True ($asyncLua -match 'representation == "BackSpace"' -and $asyncLua -match 'state\.skip_next_filter = true') 'Backspace bypasses one async page scan on the latency-sensitive delete path'
$forbiddenLua = '(?i)os\.execute|io\.popen|io\.open|Start-Process|Invoke-(RestMethod|WebRequest)|chat/completions|/translate|synthetic|set_timeout|timer'
Assert-True ($asyncLua -notmatch $forbiddenLua) 'async Lua has no process, file, HTTP, synthetic-key, or timer implementation'
Assert-True ($filterLua -notmatch $forbiddenLua) 'candidate filter has no process, file, HTTP, synthetic-key, or timer implementation'
Assert-True ($asyncLua -notmatch 'refresh_non_confirmed_composition\(') 'Lua never calls the Rime refresh API directly'
Assert-True ($asyncLua -notmatch 'refresh_generation|refresh_fingerprint|refresh_ready_page_once') 'Lua has no key-driven refresh marker after native wakeup is enabled'
Assert-True ($bridge -match 'WEASEL_BILINGUAL_REFRESH_MESSAGE:\s*u32\s*=\s*WM_APP\s*\+\s*0x3a1') 'bridge and Weasel reserve one private WM_APP completion message'
Assert-True ($bridge -match 'FindWindowW' -and $bridge -match 'PostMessageW' -and $bridge -match 'wake_weasel_for_ready_completion') 'ready completion wakeup is a non-blocking window message, not a Rime API call from the worker'
Assert-True ($bridge -match 'published_ready = matches!\(terminal, Terminal::Ready' -and $bridge -match 'if published_ready \{\s*let _ = wake_weasel_for_ready_completion\(\)') 'only a published ready completion wakes Weasel'
Assert-True ($weaselWakePatch -match 'WEASEL_BILINGUAL_REFRESH_MESSAGE \(WM_APP \+ 0x3a1\)') 'Weasel patch uses the same private completion message'
Assert-True ($weaselWakePatch -match 'MESSAGE_HANDLER\(WEASEL_BILINGUAL_REFRESH_MESSAGE, OnBilingualRefresh\)') 'Weasel IPC window handles completion on its message loop'
Assert-True ($weaselWakePatch -match 'm_active_session' -and $weaselWakePatch -match 'is_composing') 'main-thread wakeup is restricted to the active composing session'
Assert-True ($weaselWakePatch -match '_rime_bilingual_refresh' -and $weaselWakePatch -match 'rime_api->set_option') 'Weasel refreshes through the public Rime option API on its main thread'
Assert-True ($weaselNoMfcPatch -match 'WeaselServer/afxres\.h' -and $weaselNoMfcPatch -match '#include <winres\.h>') 'Weasel build uses the Windows SDK resource definitions without requiring MFC'
Assert-True ($architecture -match 'PostMessage' -and $architecture -match '_rime_bilingual_refresh') 'architecture documents native completion wakeup and main-thread Rime refresh'

# Native backpressure, stale identity, privacy checks, and dead-Helper timeout are executable Rust tests.
Assert-True ($bridge -match 'mpsc::sync_channel\(PENDING_CAPACITY\)') 'bridge uses a bounded pending channel'
Assert-True ($bridge -match '\.try_send\(') 'bridge enqueue is non-waiting'
Assert-True ($bridge -match '\.try_lock\(') 'bridge hot-path locks fail immediately instead of waiting'
Assert-True ($bridge -match 'CurrentIsPassword\(\)') 'worker reads the focused element password property'
Assert-True ($bridge -match 'GetForegroundWindow\(\)') 'worker checks foreground identity around UIA'
Assert-True ($bridge -match 'Terminal::Failed\("stale"\)') 'bridge has terminal stale-result rejection'
Assert-True ($bridge -match 'fn hot_path_primitives_are_sub_millisecond_p99\(\)') 'bridge has a hot-path latency/backpressure test'
Assert-True ($bridge -match 'fn dead_helper_is_bounded_by_worker_timeout\(\)') 'bridge has a dead-Helper timeout test'
Assert-True ($bridge -match 'fn safety_abstraction_fails_closed\(\)') 'bridge has a fail-closed safety test'

# Helper keeps v1/v2 compatibility while V0.4 backend protocol v3 adds bounded context.
Assert-True ($helper -match 'pub const PROTOCOL_VERSION: u32 = 3') 'Helper advertises protocol v3 as the latest backend protocol'
Assert-True ($helper -match '1 if request\.context\.is_empty\(\)') 'Helper keeps protocol v1 compatibility with empty context'
Assert-True ($helper -match '2 if request\.context\.is_empty\(\)') 'Helper keeps protocol v2 compatibility with exact empty context'
Assert-True ($helper -match '3 if request\.generation\.is_some\(\)') 'Helper accepts stateful protocol v3 requests'
Assert-True ($helper -match 'candidate_fingerprint') 'Helper validates and echoes the v2 fingerprint'
Assert-True ($helper -match 'normalize_context') 'Helper bounds and normalizes v3 context'
Assert-True ($helper -match 'CONTEXT_CACHE_VERSION') 'Helper namespaces context-aware cache entries'
Assert-True ($helper -match 'cache_lookup\(state, unique\.clone\(\), translation_mode\.clone\(\)\)\.await\?') 'Helper checks the context-aware SQLite key before inference'
Assert-True ($helper -match 'infer_and_cache_deduplicated') 'Helper deduplicates in-flight model misses'
Assert-True ($helper -match 'translate_single_candidate\(state, context, candidate\)\.await\?') 'Helper isolates each unique miss into its own model inference'
Assert-True ($helper -match '"grammar": translation_grammar\(1\)') 'each upstream model call is grammatically constrained to one translation'
Assert-True ($helper -match 'never output pinyin') 'singleton prompt rejects pinyin-style romanization'
Assert-True ($helper -match 'valid_translation') 'Helper rejects non-English model output before caching'
Assert-True ($helper -match 'CACHE_UNAVAILABLE') 'Helper exposes cache failure without bypassing cache-first'
Assert-True ($helper -match 'redirect\(reqwest::redirect::Policy::none\(\)\)') 'Helper disables redirects'
Assert-True ($helper -match '\.no_proxy\(\)') 'Helper disables proxy use'
Assert-True ($helperMain -match '"--cache-path"') 'Helper CLI exposes the SQLite cache path'
Assert-True ($helperMain -match '"--max-concurrency"') 'Helper CLI exposes bounded inference concurrency'
Assert-True ($helper -match 'async fn v2_full_cache_skips_model_and_exactly_echoes\(\)') 'Helper tests all-cache-hit zero-inference behavior'
Assert-True ($helper -match 'async fn partial_cache_infers_unique_misses_independently_and_recombines\(\)') 'Helper tests singleton partial-miss inference and page-order recombination'
Assert-True ($helper -match 'async fn concurrent_identical_misses_are_deduplicated\(\)') 'Helper tests concurrent in-flight deduplication'
Assert-True ($helper -match 'async fn timeout_does_not_write_cache\(\)') 'Helper tests timeout without cache pollution'
Assert-True ($helper -match 'async fn v3_normalizes_context_sends_it_to_model_and_isolates_cache\(\)') 'Helper tests contextual cache isolation and raw-context privacy'
Assert-True ($helper -match 'async fn v3_rejects_non_english_model_output_and_does_not_cache_it\(\)') 'Helper tests English-only fail-closed output validation'

if (-not $SkipCargo) {
    & cargo test --locked --manifest-path (Join-Path $projectRoot 'bridge\Cargo.toml')
    Assert-True ($LASTEXITCODE -eq 0) 'native bridge Rust tests pass'
    & cargo test --locked --manifest-path (Join-Path $projectRoot 'helper\Cargo.toml')
    Assert-True ($LASTEXITCODE -eq 0) 'Helper Rust tests pass'
}

if ($script:Failures -gt 0) { throw "$($script:Failures) async contract test(s) failed." }
Write-Host 'All V0.3 async contract tests passed.' -ForegroundColor Green
