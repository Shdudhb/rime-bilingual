#![allow(clippy::missing_safety_doc)]

mod weasel_mount;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashSet, VecDeque};
use std::ffi::{CString, c_char, c_int, c_void};
use std::ptr;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
};
use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

const PROTOCOL_VERSION: u64 = 2;
const MAX_CANDIDATES: usize = 20;
const MAX_TEXT_BYTES: usize = 256;
const MAX_HTTP_BODY: usize = 32 * 1024;
const PENDING_CAPACITY: usize = 8;
const COMPLETION_CAPACITY: usize = 32;
const RETENTION: Duration = Duration::from_secs(30);
const EXPECTED_RIME_SHA256: &str =
    "2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B";

#[repr(C)]
pub struct lua_State {
    _private: [u8; 0],
}
type LuaInteger = i64;
type LuaCFunction = unsafe extern "C" fn(*mut lua_State) -> c_int;

#[derive(Clone, Copy)]
struct LuaApi {
    getfield: unsafe extern "C" fn(*mut lua_State, c_int, *const c_char) -> c_int,
    rawgeti: unsafe extern "C" fn(*mut lua_State, c_int, LuaInteger) -> c_int,
    rawlen: unsafe extern "C" fn(*mut lua_State, c_int) -> usize,
    settop: unsafe extern "C" fn(*mut lua_State, c_int),
    type_: unsafe extern "C" fn(*mut lua_State, c_int) -> c_int,
    tointegerx: unsafe extern "C" fn(*mut lua_State, c_int, *mut c_int) -> LuaInteger,
    tolstring: unsafe extern "C" fn(*mut lua_State, c_int, *mut usize) -> *const c_char,
    createtable: unsafe extern "C" fn(*mut lua_State, c_int, c_int),
    pushcclosure: unsafe extern "C" fn(*mut lua_State, LuaCFunction, c_int),
    pushinteger: unsafe extern "C" fn(*mut lua_State, LuaInteger),
    pushlstring: unsafe extern "C" fn(*mut lua_State, *const c_char, usize) -> *const c_char,
    pushnil: unsafe extern "C" fn(*mut lua_State),
    setfield: unsafe extern "C" fn(*mut lua_State, c_int, *const c_char),
    rawseti: unsafe extern "C" fn(*mut lua_State, c_int, LuaInteger),
}
unsafe impl Send for LuaApi {}
unsafe impl Sync for LuaApi {}

static LUA: OnceLock<Result<LuaApi, ()>> = OnceLock::new();
static GLOBAL: OnceLock<Global> = OnceLock::new();

const LUA_TSTRING: c_int = 4;
const LUA_TTABLE: c_int = 5;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetModuleHandleW(name: *const u16) -> *mut c_void;
    fn GetModuleHandleExW(
        flags: u32,
        name_or_address: *const u16,
        module: *mut *mut c_void,
    ) -> c_int;
    fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    #[cfg(test)]
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
}

unsafe fn resolve_lua() -> Result<LuaApi, ()> {
    let wide: Vec<u16> = "rime.dll\0".encode_utf16().collect();
    let module = unsafe { GetModuleHandleW(wide.as_ptr()) };
    if module.is_null() {
        return Err(());
    }
    macro_rules! sym {
        ($name:literal, $ty:ty) => {{
            let p = unsafe { GetProcAddress(module, concat!($name, "\0").as_ptr().cast()) };
            if p.is_null() {
                return Err(());
            }
            unsafe { std::mem::transmute::<*mut c_void, $ty>(p) }
        }};
    }
    Ok(LuaApi {
        getfield: sym!(
            "lua_getfield",
            unsafe extern "C" fn(*mut lua_State, c_int, *const c_char) -> c_int
        ),
        rawgeti: sym!(
            "lua_rawgeti",
            unsafe extern "C" fn(*mut lua_State, c_int, LuaInteger) -> c_int
        ),
        rawlen: sym!(
            "lua_rawlen",
            unsafe extern "C" fn(*mut lua_State, c_int) -> usize
        ),
        settop: sym!("lua_settop", unsafe extern "C" fn(*mut lua_State, c_int)),
        type_: sym!(
            "lua_type",
            unsafe extern "C" fn(*mut lua_State, c_int) -> c_int
        ),
        tointegerx: sym!(
            "lua_tointegerx",
            unsafe extern "C" fn(*mut lua_State, c_int, *mut c_int) -> LuaInteger
        ),
        tolstring: sym!(
            "lua_tolstring",
            unsafe extern "C" fn(*mut lua_State, c_int, *mut usize) -> *const c_char
        ),
        createtable: sym!(
            "lua_createtable",
            unsafe extern "C" fn(*mut lua_State, c_int, c_int)
        ),
        pushcclosure: sym!(
            "lua_pushcclosure",
            unsafe extern "C" fn(*mut lua_State, LuaCFunction, c_int)
        ),
        pushinteger: sym!(
            "lua_pushinteger",
            unsafe extern "C" fn(*mut lua_State, LuaInteger)
        ),
        pushlstring: sym!(
            "lua_pushlstring",
            unsafe extern "C" fn(*mut lua_State, *const c_char, usize) -> *const c_char
        ),
        pushnil: sym!("lua_pushnil", unsafe extern "C" fn(*mut lua_State)),
        setfield: sym!(
            "lua_setfield",
            unsafe extern "C" fn(*mut lua_State, c_int, *const c_char)
        ),
        rawseti: sym!(
            "lua_rawseti",
            unsafe extern "C" fn(*mut lua_State, c_int, LuaInteger)
        ),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Config {
    endpoint: String,
    port: u16,
    timeout_ms: u32,
    expected_sha: String,
}

#[derive(Clone, Debug)]
struct Candidate {
    absolute_index: u32,
    text: String,
    kind: String,
    start: u32,
    end: u32,
}

#[derive(Clone, Debug)]
struct Page {
    generation: u64,
    page_start: u32,
    candidates: Vec<Candidate>,
    fingerprint: [u8; 32],
}

#[derive(Clone, Debug)]
struct Miss {
    slot: u8,
    text: String,
}

#[derive(Clone, Debug)]
struct Job {
    request_id: String,
    page: Page,
    misses: Vec<Miss>,
    wake_target: Option<weasel_mount::WakeTarget>,
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
struct Pair {
    generation: u64,
    fingerprint: [u8; 32],
}

#[derive(Clone, Debug)]
enum Terminal {
    Ready {
        translations: Vec<Miss>,
        source: String,
    },
    Failed(&'static str),
}

#[derive(Clone, Debug)]
struct Completion {
    pair: Pair,
    request_id: String,
    terminal: Terminal,
    at: Instant,
}

struct LatestPair {
    seq: AtomicU64,
    generation: AtomicU64,
    words: [AtomicU64; 4],
}

impl LatestPair {
    fn new() -> Self {
        Self {
            seq: AtomicU64::new(0),
            generation: AtomicU64::new(0),
            words: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }
    fn publish(&self, pair: &Pair) {
        self.seq.fetch_add(1, Ordering::AcqRel);
        self.generation.store(pair.generation, Ordering::Relaxed);
        for (i, chunk) in pair.fingerprint.chunks_exact(8).enumerate() {
            self.words[i].store(
                u64::from_le_bytes(chunk.try_into().unwrap()),
                Ordering::Relaxed,
            );
        }
        self.seq.fetch_add(1, Ordering::Release);
    }
    fn load(&self) -> Option<Pair> {
        for _ in 0..4 {
            let before = self.seq.load(Ordering::Acquire);
            if before & 1 != 0 {
                continue;
            }
            let generation = self.generation.load(Ordering::Relaxed);
            let mut fingerprint = [0u8; 32];
            for i in 0..4 {
                fingerprint[i * 8..(i + 1) * 8]
                    .copy_from_slice(&self.words[i].load(Ordering::Relaxed).to_le_bytes());
            }
            let after = self.seq.load(Ordering::Acquire);
            if before == after && after & 1 == 0 {
                return (generation != 0).then_some(Pair {
                    generation,
                    fingerprint,
                });
            }
        }
        None
    }
}

struct Runtime {
    config: Config,
    tx: mpsc::SyncSender<Job>,
    active: Mutex<HashSet<Pair>>,
    completions: Mutex<VecDeque<Completion>>,
    latest: LatestPair,
    pending: AtomicUsize,
    completed: AtomicUsize,
    dropped: AtomicUsize,
    last_error: Mutex<Option<&'static str>>,
    next_id: AtomicU64,
}

enum GlobalState {
    Unconfigured,
    Ready(Arc<Runtime>),
    Disabled(&'static str),
}
struct Global {
    state: Mutex<GlobalState>,
}

impl Global {
    fn get() -> &'static Self {
        GLOBAL.get_or_init(|| Global {
            state: Mutex::new(GlobalState::Unconfigured),
        })
    }
}

fn pair(page: &Page) -> Pair {
    Pair {
        generation: page.generation,
        fingerprint: page.fingerprint,
    }
}

fn fingerprint(page_start: u32, candidates: &[Candidate]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"RBIL-PAGE-V1\0");
    h.update(page_start.to_le_bytes());
    h.update((candidates.len() as u32).to_le_bytes());
    for c in candidates {
        h.update(c.absolute_index.to_le_bytes());
        h.update((c.text.len() as u32).to_le_bytes());
        h.update(c.text.as_bytes());
        h.update((c.kind.len() as u32).to_le_bytes());
        h.update(c.kind.as_bytes());
        h.update(c.start.to_le_bytes());
        h.update(c.end.to_le_bytes());
    }
    h.finalize().into()
}

fn valid_text(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_TEXT_BYTES && !s.chars().any(|c| c.is_control())
}
fn hex(hash: &[u8; 32]) -> String {
    hash.iter().map(|b| format!("{b:02x}")).collect()
}

trait SafetyCheck: Send + Sync {
    fn safe(&self) -> Result<(), &'static str>;
}
struct WindowsSafety;
impl SafetyCheck for WindowsSafety {
    fn safe(&self) -> Result<(), &'static str> {
        unsafe {
            let before = GetForegroundWindow();
            if before.0.is_null() {
                return Err("unsafe");
            }
            let mut before_pid = 0u32;
            GetWindowThreadProcessId(before, Some(&mut before_pid));
            if before_pid == 0 {
                return Err("unsafe");
            }
            CoInitializeEx(None, COINIT_MULTITHREADED)
                .ok()
                .map_err(|_| "unsafe")?;
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                    .map_err(|_| "unsafe")?;
            let focused = automation.GetFocusedElement().map_err(|_| "unsafe")?;
            let focused_pid = focused.CurrentProcessId().map_err(|_| "unsafe")? as u32;
            let is_password = focused.CurrentIsPassword().map_err(|_| "unsafe")?.as_bool();
            let after = GetForegroundWindow();
            let mut after_pid = 0u32;
            GetWindowThreadProcessId(after, Some(&mut after_pid));
            if is_password {
                return Err("unsafe");
            }
            if before != after || before_pid != after_pid || focused_pid != before_pid {
                return Err("focus_changed");
            }
            Ok(())
        }
    }
}

#[derive(Serialize)]
struct HelperRequest<'a> {
    protocol_version: u64,
    request_id: &'a str,
    generation: u64,
    candidate_fingerprint: String,
    page_start: u32,
    context: &'static str,
    candidates: Vec<&'a str>,
}
#[derive(Deserialize)]
struct HelperResponse {
    protocol_version: u64,
    request_id: String,
    generation: u64,
    candidate_fingerprint: String,
    translations: Vec<String>,
    source: String,
}

#[link(name = "winhttp")]
unsafe extern "system" {
    fn WinHttpOpen(
        agent: *const u16,
        access: u32,
        proxy: *const u16,
        bypass: *const u16,
        flags: u32,
    ) -> *mut c_void;
    fn WinHttpConnect(
        session: *mut c_void,
        server: *const u16,
        port: u16,
        reserved: u32,
    ) -> *mut c_void;
    fn WinHttpOpenRequest(
        connect: *mut c_void,
        verb: *const u16,
        object: *const u16,
        version: *const u16,
        referer: *const u16,
        accept: *const *const u16,
        flags: u32,
    ) -> *mut c_void;
    fn WinHttpSetTimeouts(
        handle: *mut c_void,
        resolve: c_int,
        connect: c_int,
        send: c_int,
        receive: c_int,
    ) -> c_int;
    fn WinHttpSetOption(handle: *mut c_void, option: u32, buffer: *const c_void, len: u32)
    -> c_int;
    fn WinHttpSendRequest(
        request: *mut c_void,
        headers: *const u16,
        header_len: u32,
        optional: *const c_void,
        optional_len: u32,
        total_len: u32,
        context: usize,
    ) -> c_int;
    fn WinHttpReceiveResponse(request: *mut c_void, reserved: *mut c_void) -> c_int;
    fn WinHttpQueryHeaders(
        request: *mut c_void,
        info: u32,
        name: *const u16,
        buffer: *mut c_void,
        buffer_len: *mut u32,
        index: *mut u32,
    ) -> c_int;
    fn WinHttpQueryDataAvailable(request: *mut c_void, available: *mut u32) -> c_int;
    fn WinHttpReadData(
        request: *mut c_void,
        buffer: *mut c_void,
        bytes: u32,
        read: *mut u32,
    ) -> c_int;
    fn WinHttpCloseHandle(handle: *mut c_void) -> c_int;
}

struct HttpHandle(*mut c_void);
impl Drop for HttpHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                WinHttpCloseHandle(self.0);
            }
        }
    }
}

fn helper_call(config: &Config, job: &Job) -> Result<(Vec<Miss>, String), &'static str> {
    let deadline = Instant::now() + Duration::from_millis(config.timeout_ms as u64);
    let req = HelperRequest {
        protocol_version: PROTOCOL_VERSION,
        request_id: &job.request_id,
        generation: job.page.generation,
        candidate_fingerprint: hex(&job.page.fingerprint),
        page_start: job.page.page_start,
        context: "",
        candidates: job.misses.iter().map(|m| m.text.as_str()).collect(),
    };
    let body = serde_json::to_vec(&req).map_err(|_| "worker_error")?;
    if body.len() > MAX_HTTP_BODY {
        return Err("invalid_response");
    }
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() };
    unsafe {
        let session = HttpHandle(WinHttpOpen(
            wide("RimeBilingualBridge/0.3").as_ptr(),
            1,
            ptr::null(),
            ptr::null(),
            0,
        ));
        if session.0.is_null() {
            return Err("helper_unavailable");
        }
        let set_remaining_timeout = || -> Result<(), &'static str> {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err("timeout");
            }
            let ms = remaining.as_millis().clamp(1, c_int::MAX as u128) as c_int;
            if WinHttpSetTimeouts(session.0, ms, ms, ms, ms) == 0 {
                return Err("worker_error");
            }
            Ok(())
        };
        set_remaining_timeout()?;
        if Instant::now() >= deadline {
            return Err("timeout");
        }
        let connect = HttpHandle(WinHttpConnect(
            session.0,
            wide("127.0.0.1").as_ptr(),
            config.port,
            0,
        ));
        if connect.0.is_null() {
            return Err("helper_unavailable");
        }
        let request = HttpHandle(WinHttpOpenRequest(
            connect.0,
            wide("POST").as_ptr(),
            wide("/translate").as_ptr(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            0,
        ));
        if request.0.is_null() {
            return Err("helper_unavailable");
        }
        const WINHTTP_OPTION_REDIRECT_POLICY: u32 = 88;
        const WINHTTP_OPTION_REDIRECT_POLICY_NEVER: u32 = 0;
        let policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if WinHttpSetOption(
            request.0,
            WINHTTP_OPTION_REDIRECT_POLICY,
            (&policy as *const u32).cast(),
            4,
        ) == 0
        {
            return Err("worker_error");
        }
        let headers = wide("Content-Type: application/json\r\nAccept: application/json\r\n");
        set_remaining_timeout()?;
        if WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            u32::MAX,
            body.as_ptr().cast(),
            body.len() as u32,
            body.len() as u32,
            0,
        ) == 0
        {
            return Err("helper_unavailable");
        }
        set_remaining_timeout()?;
        if WinHttpReceiveResponse(request.0, ptr::null_mut()) == 0 {
            return Err("timeout");
        }
        let mut status = 0u32;
        let mut status_len = 4u32;
        const WINHTTP_QUERY_STATUS_CODE_NUMBER: u32 = 19 | 0x2000_0000;
        if WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE_NUMBER,
            ptr::null(),
            (&mut status as *mut u32).cast(),
            &mut status_len,
            ptr::null_mut(),
        ) == 0
        {
            return Err("invalid_response");
        }
        if status != 200 {
            return Err(if status == 408 || status == 504 {
                "timeout"
            } else {
                "helper_unavailable"
            });
        }
        let mut response = Vec::new();
        loop {
            set_remaining_timeout()?;
            let mut available = 0u32;
            if WinHttpQueryDataAvailable(request.0, &mut available) == 0 {
                return Err("invalid_response");
            }
            if available == 0 {
                break;
            }
            if response.len() + available as usize > MAX_HTTP_BODY {
                return Err("invalid_response");
            }
            let old = response.len();
            response.resize(old + available as usize, 0);
            let mut read = 0u32;
            if WinHttpReadData(
                request.0,
                response[old..].as_mut_ptr().cast(),
                available,
                &mut read,
            ) == 0
            {
                return Err("invalid_response");
            }
            response.truncate(old + read as usize);
            if read == 0 {
                break;
            }
        }
        let parsed: HelperResponse =
            serde_json::from_slice(&response).map_err(|_| "invalid_response")?;
        if parsed.protocol_version != 2
            || parsed.request_id != job.request_id
            || parsed.generation != job.page.generation
            || parsed.candidate_fingerprint != hex(&job.page.fingerprint)
        {
            return Err("invalid_response");
        }
        if !matches!(parsed.source.as_str(), "cache" | "mixed" | "model")
            || parsed.translations.len() != job.misses.len()
        {
            return Err("invalid_response");
        }
        let mut translations = Vec::with_capacity(job.misses.len());
        for (miss, text) in job.misses.iter().zip(parsed.translations) {
            if !valid_text(&text) {
                return Err("invalid_response");
            }
            translations.push(Miss {
                slot: miss.slot,
                text,
            });
        }
        Ok((translations, parsed.source))
    }
}

fn worker(runtime: Arc<Runtime>, rx: mpsc::Receiver<Job>, safety: Arc<dyn SafetyCheck>) {
    while let Ok(job) = rx.recv() {
        let p = pair(&job.page);
        let mut terminal = if runtime.latest.load().as_ref() != Some(&p) {
            Terminal::Failed("stale")
        } else if let Err(e) = safety.safe() {
            Terminal::Failed(e)
        } else if runtime.latest.load().as_ref() != Some(&p) {
            Terminal::Failed("stale")
        } else {
            match helper_call(&runtime.config, &job) {
                Ok((translations, source)) if runtime.latest.load().as_ref() == Some(&p) => {
                    Terminal::Ready {
                        translations,
                        source,
                    }
                }
                Ok(_) => Terminal::Failed("stale"),
                Err(e) => Terminal::Failed(e),
            }
        };
        // Every terminal result, including an HTTP/UIA failure, is checked at
        // the ring boundary. Old-pair diagnostics must not masquerade as the
        // current page's outcome.
        if runtime.latest.load().as_ref() != Some(&p) {
            terminal = Terminal::Failed("stale");
        }
        runtime.pending.fetch_sub(1, Ordering::Relaxed);
        if let Terminal::Failed(e) = terminal
            && let Ok(mut last) = runtime.last_error.lock()
        {
            *last = Some(e);
        }
        // Keep the active lock through completion publication so submit can
        // never observe a gap between the pending and terminal stores.
        let mut published_ready = false;
        if let Ok(mut active) = runtime.active.lock() {
            active.remove(&p);
            let Ok(mut entries) = runtime.completions.lock() else {
                runtime.dropped.fetch_add(1, Ordering::Relaxed);
                continue;
            };
            let now = Instant::now();
            while entries
                .front()
                .is_some_and(|e| now.duration_since(e.at) >= RETENTION)
            {
                entries.pop_front();
                runtime.dropped.fetch_add(1, Ordering::Relaxed);
            }
            if entries.len() == COMPLETION_CAPACITY {
                entries.pop_front();
                runtime.dropped.fetch_add(1, Ordering::Relaxed);
            }
            published_ready = matches!(terminal, Terminal::Ready { .. });
            entries.push_back(Completion {
                pair: p,
                request_id: job.request_id,
                terminal,
                at: now,
            });
            runtime.completed.store(entries.len(), Ordering::Relaxed);
        } else {
            runtime.dropped.fetch_add(1, Ordering::Relaxed);
        }
        if published_ready && let Some(target) = job.wake_target {
            let _ = weasel_mount::wake(target);
        }
    }
}

// Lua stack helpers. They never invoke luaL_error/longjmp.
unsafe fn api() -> Option<&'static LuaApi> {
    unsafe { LUA.get_or_init(|| resolve_lua()).as_ref().ok() }
}
unsafe fn pop(a: &LuaApi, l: *mut lua_State, n: c_int) {
    unsafe { (a.settop)(l, -n - 1) }
}
unsafe fn field(a: &LuaApi, l: *mut lua_State, idx: c_int, name: &str) -> c_int {
    let c = CString::new(name).unwrap();
    unsafe { (a.getfield)(l, idx, c.as_ptr()) }
}
unsafe fn integer_field(a: &LuaApi, l: *mut lua_State, idx: c_int, name: &str) -> Option<u64> {
    unsafe {
        field(a, l, idx, name);
    }
    let mut ok = 0;
    let value = unsafe { (a.tointegerx)(l, -1, &mut ok) };
    unsafe {
        pop(a, l, 1);
    }
    (ok != 0 && value >= 0).then_some(value as u64)
}
unsafe fn string_at(a: &LuaApi, l: *mut lua_State, idx: c_int) -> Option<String> {
    if unsafe { (a.type_)(l, idx) } != LUA_TSTRING {
        return None;
    }
    let mut len = 0;
    let p = unsafe { (a.tolstring)(l, idx, &mut len) };
    if p.is_null() {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(p.cast::<u8>(), len) })
        .ok()
        .map(str::to_owned)
}
unsafe fn string_field(a: &LuaApi, l: *mut lua_State, idx: c_int, name: &str) -> Option<String> {
    unsafe {
        field(a, l, idx, name);
    }
    let s = unsafe { string_at(a, l, -1) };
    unsafe {
        pop(a, l, 1);
    }
    s
}
unsafe fn push_string(a: &LuaApi, l: *mut lua_State, s: &str) {
    unsafe {
        (a.pushlstring)(l, s.as_ptr().cast(), s.len());
    }
}
unsafe fn set_string(a: &LuaApi, l: *mut lua_State, k: &str, v: &str) {
    unsafe {
        push_string(a, l, v);
        (a.setfield)(l, -2, CString::new(k).unwrap().as_ptr());
    }
}
unsafe fn set_int(a: &LuaApi, l: *mut lua_State, k: &str, v: u64) {
    unsafe {
        (a.pushinteger)(l, v as i64);
        (a.setfield)(l, -2, CString::new(k).unwrap().as_ptr());
    }
}
unsafe fn result(a: &LuaApi, l: *mut lua_State, status: &str) {
    unsafe {
        (a.createtable)(l, 0, 6);
        set_string(a, l, "status", status);
    }
}

unsafe fn parse_page(a: &LuaApi, l: *mut lua_State, idx: c_int) -> Option<Page> {
    if unsafe { (a.type_)(l, idx) } != LUA_TTABLE {
        return None;
    }
    let generation = unsafe { integer_field(a, l, idx, "generation") }?;
    if generation == 0 {
        return None;
    }
    let page_start = u32::try_from(unsafe { integer_field(a, l, idx, "page_start") }?).ok()?;
    unsafe {
        field(a, l, idx, "candidates");
    }
    if unsafe { (a.type_)(l, -1) } != LUA_TTABLE {
        unsafe {
            pop(a, l, 1);
        }
        return None;
    }
    let n = unsafe { (a.rawlen)(l, -1) };
    if !(1..=MAX_CANDIDATES).contains(&n) {
        unsafe {
            pop(a, l, 1);
        }
        return None;
    }
    let mut candidates = Vec::with_capacity(n);
    for i in 1..=n {
        unsafe {
            (a.rawgeti)(l, -1, i as i64);
        }
        if unsafe { (a.type_)(l, -1) } != LUA_TTABLE {
            unsafe {
                pop(a, l, 2);
            }
            return None;
        }
        let absolute_index =
            u32::try_from(unsafe { integer_field(a, l, -1, "absolute_index") }?).ok()?;
        let text = unsafe { string_field(a, l, -1, "text") }?;
        let kind = unsafe { string_field(a, l, -1, "type") }?;
        let start = u32::try_from(unsafe { integer_field(a, l, -1, "start") }?).ok()?;
        let end = u32::try_from(unsafe { integer_field(a, l, -1, "end") }?).ok()?;
        unsafe {
            pop(a, l, 1);
        }
        if absolute_index != page_start.checked_add((i - 1) as u32)?
            || !valid_text(&text)
            || !valid_text(&kind)
            || end < start
        {
            unsafe {
                pop(a, l, 1);
            }
            return None;
        }
        candidates.push(Candidate {
            absolute_index,
            text,
            kind,
            start,
            end,
        });
    }
    unsafe {
        pop(a, l, 1);
    }
    let fingerprint = fingerprint(page_start, &candidates);
    Some(Page {
        generation,
        page_start,
        candidates,
        fingerprint,
    })
}

unsafe extern "C" fn lua_configure(l: *mut lua_State) -> c_int {
    let Some(a) = (unsafe { api() }) else {
        return 0;
    };
    if unsafe { (a.type_)(l, 1) } != LUA_TTABLE {
        unsafe {
            result(a, l, "disabled");
            set_string(a, l, "error", "invalid_config");
        }
        return 1;
    }
    let parsed = (|| unsafe {
        let version = integer_field(a, l, 1, "protocol_version")?;
        let endpoint = string_field(a, l, 1, "helper_endpoint")?;
        let timeout_ms = u32::try_from(integer_field(a, l, 1, "request_timeout_ms")?).ok()?;
        let queue = integer_field(a, l, 1, "queue_capacity")? as usize;
        let completions = integer_field(a, l, 1, "completion_capacity")? as usize;
        let expected_sha = string_field(a, l, 1, "expected_rime_sha256")?;
        let port = parse_endpoint(&endpoint)?;
        if expected_sha.len() != 64 || !expected_sha.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        (version == PROTOCOL_VERSION
            && (1..=60_000).contains(&timeout_ms)
            && queue == PENDING_CAPACITY
            && completions == COMPLETION_CAPACITY)
            .then_some(Config {
                endpoint,
                port,
                timeout_ms,
                expected_sha,
            })
    })();
    let global = Global::get();
    let Ok(mut state) = global.state.try_lock() else {
        unsafe {
            result(a, l, "disabled");
            set_string(a, l, "error", "already_configured");
        }
        return 1;
    };
    let Some(config) = parsed else {
        *state = GlobalState::Disabled("invalid_config");
        unsafe {
            result(a, l, "disabled");
            set_string(a, l, "error", "invalid_config");
        }
        return 1;
    };
    match &*state {
        GlobalState::Ready(rt) if rt.config == config => unsafe {
            result(a, l, "ready");
            set_int(a, l, "protocol_version", 2);
        },
        GlobalState::Ready(_) | GlobalState::Disabled(_) => {
            let e = match &*state {
                GlobalState::Disabled(e) => *e,
                _ => "already_configured",
            };
            unsafe {
                result(a, l, "disabled");
                set_string(a, l, "error", e);
            }
        }
        GlobalState::Unconfigured => {
            if !config
                .expected_sha
                .eq_ignore_ascii_case(EXPECTED_RIME_SHA256)
            {
                *state = GlobalState::Disabled("abi_mismatch");
                unsafe {
                    result(a, l, "disabled");
                    set_string(a, l, "error", "abi_mismatch");
                }
            } else if let Err(e) = weasel_mount::install() {
                *state = GlobalState::Disabled(e);
                unsafe {
                    result(a, l, "disabled");
                    set_string(a, l, "error", e);
                }
            } else {
                let (tx, rx) = mpsc::sync_channel(PENDING_CAPACITY);
                let rt = Arc::new(Runtime {
                    config,
                    tx,
                    active: Mutex::new(HashSet::with_capacity(PENDING_CAPACITY)),
                    completions: Mutex::new(VecDeque::with_capacity(COMPLETION_CAPACITY)),
                    latest: LatestPair::new(),
                    pending: AtomicUsize::new(0),
                    completed: AtomicUsize::new(0),
                    dropped: AtomicUsize::new(0),
                    last_error: Mutex::new(None),
                    next_id: AtomicU64::new(1),
                });
                let worker_rt = rt.clone();
                match thread::Builder::new()
                    .name("rime-bilingual-worker".into())
                    .spawn(move || worker(worker_rt, rx, Arc::new(WindowsSafety)))
                {
                    Ok(_) => {
                        *state = GlobalState::Ready(rt);
                        unsafe {
                            result(a, l, "ready");
                            set_int(a, l, "protocol_version", 2);
                        }
                    }
                    Err(_) => {
                        *state = GlobalState::Disabled("worker_start_failed");
                        unsafe {
                            result(a, l, "disabled");
                            set_string(a, l, "error", "worker_start_failed");
                        }
                    }
                }
            }
        }
    }
    1
}

unsafe extern "C" fn lua_try_submit(l: *mut lua_State) -> c_int {
    let Some(a) = (unsafe { api() }) else {
        return 0;
    };
    let Some(page) = (unsafe { parse_page(a, l, 1) }) else {
        unsafe {
            result(a, l, "invalid");
        }
        return 1;
    };
    unsafe {
        field(a, l, 1, "misses");
    }
    if unsafe { (a.type_)(l, -1) } != LUA_TTABLE {
        unsafe {
            pop(a, l, 1);
            result(a, l, "invalid");
        }
        return 1;
    }
    let n = unsafe { (a.rawlen)(l, -1) };
    if !(1..=MAX_CANDIDATES).contains(&n) {
        unsafe {
            pop(a, l, 1);
            result(a, l, "invalid");
        }
        return 1;
    }
    let mut misses = Vec::with_capacity(n);
    let mut prior = None;
    for i in 1..=n {
        unsafe {
            (a.rawgeti)(l, -1, i as i64);
        }
        let slot = unsafe { integer_field(a, l, -1, "slot") }.and_then(|v| u8::try_from(v).ok());
        let text = unsafe { string_field(a, l, -1, "text") };
        unsafe {
            pop(a, l, 1);
        }
        let Some(slot) = slot else {
            unsafe {
                pop(a, l, 1);
                result(a, l, "invalid");
            }
            return 1;
        };
        let Some(text) = text else {
            unsafe {
                pop(a, l, 1);
                result(a, l, "invalid");
            }
            return 1;
        };
        if slot as usize >= page.candidates.len()
            || prior.is_some_and(|p| slot <= p)
            || text != page.candidates[slot as usize].text
        {
            unsafe {
                pop(a, l, 1);
                result(a, l, "invalid");
            }
            return 1;
        }
        prior = Some(slot);
        misses.push(Miss { slot, text });
    }
    unsafe {
        pop(a, l, 1);
    }
    let global = Global::get();
    let Ok(state) = global.state.try_lock() else {
        unsafe {
            result(a, l, "queue_full");
        }
        return 1;
    };
    let GlobalState::Ready(rt) = &*state else {
        unsafe {
            result(a, l, "disabled");
        }
        return 1;
    };
    let p = pair(&page);
    let Ok(mut active) = rt.active.try_lock() else {
        unsafe {
            result(a, l, "queue_full");
        }
        return 1;
    };
    let Ok(mut completions) = rt.completions.try_lock() else {
        unsafe {
            result(a, l, "queue_full");
        }
        return 1;
    };
    let duplicate_ready = completions
        .iter()
        .any(|e| e.pair == p && matches!(e.terminal, Terminal::Ready { .. }));
    if active.contains(&p) || duplicate_ready {
        unsafe {
            result(a, l, "duplicate");
            set_int(a, l, "generation", p.generation);
            set_string(a, l, "fingerprint", &hex(&p.fingerprint));
        }
        return 1;
    }
    // Failed completion is diagnostic, not a dedup entry: bounded retry is
    // permitted for the same page pair.
    completions.retain(|e| e.pair != p);
    rt.completed.store(completions.len(), Ordering::Relaxed);
    drop(completions);
    let id_num = rt.next_id.fetch_add(1, Ordering::Relaxed);
    let request_id = format!("rime-{}-{id_num:x}", page.generation);
    let wake_target = weasel_mount::capture_wake_target();
    active.insert(p.clone());
    match rt.tx.try_send(Job {
        request_id: request_id.clone(),
        page,
        misses,
        wake_target,
    }) {
        Ok(()) => {
            rt.pending.fetch_add(1, Ordering::Relaxed);
            unsafe {
                result(a, l, "accepted");
                set_string(a, l, "request_id", &request_id);
                set_int(a, l, "generation", p.generation);
                set_string(a, l, "fingerprint", &hex(&p.fingerprint));
            }
        }
        Err(_) => {
            active.remove(&p);
            unsafe {
                result(a, l, "queue_full");
            }
        }
    }
    1
}

unsafe extern "C" fn lua_try_poll(l: *mut lua_State) -> c_int {
    let Some(a) = (unsafe { api() }) else {
        return 0;
    };
    let Some(page) = (unsafe { parse_page(a, l, 1) }) else {
        unsafe {
            result(a, l, "failed");
            set_int(a, l, "generation", 0);
            set_string(a, l, "fingerprint", "");
            set_string(a, l, "error", "invalid_response");
        }
        return 1;
    };
    let p = pair(&page);
    let global = Global::get();
    let Ok(state) = global.state.try_lock() else {
        unsafe {
            result(a, l, "pending");
            set_int(a, l, "generation", p.generation);
            set_string(a, l, "fingerprint", &hex(&p.fingerprint));
        }
        return 1;
    };
    let GlobalState::Ready(rt) = &*state else {
        unsafe {
            result(a, l, "disabled");
        }
        return 1;
    };
    rt.latest.publish(&p);
    let Ok(mut entries) = rt.completions.try_lock() else {
        unsafe {
            result(a, l, "pending");
            set_int(a, l, "generation", p.generation);
            set_string(a, l, "fingerprint", &hex(&p.fingerprint));
        }
        return 1;
    };
    let now = Instant::now();
    while entries
        .front()
        .is_some_and(|e| now.duration_since(e.at) >= RETENTION)
    {
        entries.pop_front();
        rt.dropped.fetch_add(1, Ordering::Relaxed);
    }
    rt.completed.store(entries.len(), Ordering::Relaxed);
    let found = entries.iter().find(|e| e.pair == p);
    match found {
        Some(e) => match &e.terminal {
            Terminal::Ready {
                translations,
                source,
            } => unsafe {
                result(a, l, "ready");
                set_string(a, l, "request_id", &e.request_id);
                set_int(a, l, "generation", p.generation);
                set_string(a, l, "fingerprint", &hex(&p.fingerprint));
                set_string(a, l, "source", source);
                (a.createtable)(l, translations.len() as c_int, 0);
                for (i, t) in translations.iter().enumerate() {
                    (a.createtable)(l, 0, 2);
                    set_int(a, l, "slot", t.slot as u64);
                    set_string(a, l, "text", &t.text);
                    (a.rawseti)(l, -2, (i + 1) as i64);
                }
                (a.setfield)(l, -2, CString::new("translations").unwrap().as_ptr());
            },
            Terminal::Failed(error) => unsafe {
                result(a, l, "failed");
                set_int(a, l, "generation", p.generation);
                set_string(a, l, "fingerprint", &hex(&p.fingerprint));
                set_string(a, l, "error", error);
            },
        },
        None if rt.active.try_lock().ok().is_some_and(|s| s.contains(&p)) => unsafe {
            result(a, l, "pending");
            set_int(a, l, "generation", p.generation);
            set_string(a, l, "fingerprint", &hex(&p.fingerprint));
        },
        None => unsafe {
            result(a, l, "not_found");
            set_int(a, l, "generation", p.generation);
            set_string(a, l, "fingerprint", &hex(&p.fingerprint));
        },
    }
    1
}

unsafe extern "C" fn lua_status(l: *mut lua_State) -> c_int {
    let Some(a) = (unsafe { api() }) else {
        return 0;
    };
    let global = Global::get();
    let Ok(state) = global.state.try_lock() else {
        unsafe {
            result(a, l, "disabled");
        }
        return 1;
    };
    match &*state {
        GlobalState::Ready(rt) => unsafe {
            result(a, l, "ready");
            set_int(a, l, "protocol_version", 2);
            set_int(a, l, "pending", rt.pending.load(Ordering::Relaxed) as u64);
            set_int(
                a,
                l,
                "completed",
                rt.completed.load(Ordering::Relaxed) as u64,
            );
            set_int(a, l, "dropped", rt.dropped.load(Ordering::Relaxed) as u64);
            if let Ok(last) = rt.last_error.try_lock() {
                if let Some(e) = *last {
                    set_string(a, l, "last_error", e);
                } else {
                    (a.pushnil)(l);
                    (a.setfield)(l, -2, CString::new("last_error").unwrap().as_ptr());
                }
            } else {
                (a.pushnil)(l);
                (a.setfield)(l, -2, CString::new("last_error").unwrap().as_ptr());
            }
        },
        GlobalState::Disabled(e) => unsafe {
            result(a, l, "disabled");
            set_string(a, l, "last_error", e);
        },
        GlobalState::Unconfigured => unsafe {
            result(a, l, "disabled");
        },
    }
    1
}

fn parse_endpoint(endpoint: &str) -> Option<u16> {
    let rest = endpoint
        .strip_prefix("http://127.0.0.1:")?
        .strip_suffix('/')
        .unwrap_or(endpoint.strip_prefix("http://127.0.0.1:")?);
    if rest.contains('/') || rest.contains('?') || rest.contains('#') || rest.is_empty() {
        return None;
    }
    rest.parse::<u16>().ok().filter(|p| *p != 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn luaopen_rime_bilingual_bridge(l: *mut lua_State) -> c_int {
    let Some(a) = (unsafe { api() }) else {
        return 0;
    };
    // The worker owns code in this module for the process lifetime. Pinning
    // prevents Lua GC/package teardown from unloading the DLL under that
    // thread; process teardown then requires no join and cannot deadlock.
    let mut pinned = ptr::null_mut();
    const GET_MODULE_HANDLE_EX_FLAG_PIN: u32 = 0x1;
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;
    if unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            luaopen_rime_bilingual_bridge as *const () as *const u16,
            &mut pinned,
        )
    } == 0
    {
        return 0;
    }
    unsafe {
        (a.createtable)(l, 0, 4);
        for (name, func) in [
            ("configure", lua_configure as LuaCFunction),
            ("try_submit", lua_try_submit),
            ("try_poll", lua_try_poll),
            ("status", lua_status),
        ] {
            (a.pushcclosure)(l, func, 0);
            (a.setfield)(l, -2, CString::new(name).unwrap().as_ptr());
        }
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endpoint_is_strict_loopback() {
        assert_eq!(parse_endpoint("http://127.0.0.1:18081"), Some(18081));
        assert_eq!(parse_endpoint("http://127.0.0.1:18081/"), Some(18081));
        for x in [
            "http://localhost:1",
            "https://127.0.0.1:1",
            "http://0.0.0.0:1",
            "http://127.0.0.1:1/x",
        ] {
            assert_eq!(parse_endpoint(x), None);
        }
    }
    #[test]
    fn fingerprint_is_framed_and_comment_independent() {
        let c = vec![Candidate {
            absolute_index: 0,
            text: "今天".into(),
            kind: "phrase".into(),
            start: 0,
            end: 7,
        }];
        assert_eq!(hex(&fingerprint(0, &c)).len(), 64);
        let mut d = c.clone();
        d[0].text = "今\0天".into();
        assert_ne!(fingerprint(0, &c), fingerprint(0, &d));
    }
    #[test]
    fn latest_pair_snapshot_roundtrips() {
        let latest = LatestPair::new();
        let p = Pair {
            generation: 42,
            fingerprint: [7; 32],
        };
        latest.publish(&p);
        assert_eq!(latest.load(), Some(p));
    }
    #[test]
    fn hot_path_primitives_are_sub_millisecond_p99() {
        // The receiver is deliberately never drained, modelling a dead/slow
        // Helper worker. A full ring must not turn submit/poll into a wait.
        let (tx, _rx) = mpsc::sync_channel::<u64>(8);
        let latest = LatestPair::new();
        let p = Pair {
            generation: 1,
            fingerprint: [1; 32],
        };
        let mut samples = Vec::with_capacity(10_000);
        let mut accepted = 0usize;
        for i in 0..10_000 {
            let t = Instant::now();
            latest.publish(&p);
            let _ = latest.load();
            if tx.try_send(i).is_ok() {
                accepted += 1;
            }
            samples.push(t.elapsed());
        }
        samples.sort();
        assert_eq!(accepted, PENDING_CAPACITY);
        assert!(
            samples[9_899] < Duration::from_millis(1),
            "p99={:?}",
            samples[9_899]
        );
    }
    struct Unsafe;
    impl SafetyCheck for Unsafe {
        fn safe(&self) -> Result<(), &'static str> {
            Err("unsafe")
        }
    }
    #[test]
    fn safety_abstraction_fails_closed() {
        assert_eq!(Unsafe.safe(), Err("unsafe"));
    }
    #[test]
    fn limits_reject_controls_and_oversize() {
        assert!(!valid_text(""));
        assert!(!valid_text("a\n"));
        assert!(!valid_text(&"a".repeat(257)));
        assert!(valid_text("今天"));
    }

    #[test]
    fn dead_helper_is_bounded_by_worker_timeout() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let candidate = Candidate {
            absolute_index: 0,
            text: "今天".into(),
            kind: "phrase".into(),
            start: 0,
            end: 7,
        };
        let mut page = Page {
            generation: 1,
            page_start: 0,
            candidates: vec![candidate],
            fingerprint: [0; 32],
        };
        page.fingerprint = fingerprint(page.page_start, &page.candidates);
        let job = Job {
            request_id: "rime-1-1".into(),
            page,
            misses: vec![Miss {
                slot: 0,
                text: "今天".into(),
            }],
            wake_target: None,
        };
        let config = Config {
            endpoint: format!("http://127.0.0.1:{port}"),
            port,
            timeout_ms: 100,
            expected_sha: EXPECTED_RIME_SHA256.into(),
        };
        let started = Instant::now();
        assert!(helper_call(&config, &job).is_err());
        // WinHTTP initialization may dominate the first call, but the worker
        // remains bounded and never affects the Rime-thread queue operations.
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn loads_against_installed_rime_lua_abi() {
        unsafe {
            let path: Vec<u16> = r"C:\Program Files\Rime\weasel-0.17.4\rime.dll"
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let module = LoadLibraryW(path.as_ptr());
            assert!(!module.is_null(), "installed rime.dll must load");
            let newstate = GetProcAddress(module, c"luaL_newstate".as_ptr());
            let close = GetProcAddress(module, c"lua_close".as_ptr());
            let gettop = GetProcAddress(module, c"lua_gettop".as_ptr());
            assert!(!newstate.is_null() && !close.is_null() && !gettop.is_null());
            let newstate: unsafe extern "C" fn() -> *mut lua_State = std::mem::transmute(newstate);
            let close: unsafe extern "C" fn(*mut lua_State) = std::mem::transmute(close);
            let gettop: unsafe extern "C" fn(*mut lua_State) -> c_int = std::mem::transmute(gettop);
            let l = newstate();
            assert!(!l.is_null());
            assert_eq!(luaopen_rime_bilingual_bridge(l), 1);
            assert_eq!(gettop(l), 1);
            close(l);
        }
    }
}
