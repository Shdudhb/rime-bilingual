use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::ffi::{c_char, c_int, c_void};
use std::fs::File;
use std::io::Read;
use std::mem::size_of;
use std::ptr;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, WM_APP};

const EXPECTED_WEASEL_SERVER_SHA256: &str =
    "FEF5AF4516092A1CA26E4E307D118583AD3FF5DF547A35FB66CB490FF99EF35B";
const EXPECTED_RIME_SHA256: &str =
    "2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B";

const WEASEL_IPC_ECHO: u32 = WM_APP + 1;
const WEASEL_IPC_END_SESSION: u32 = WM_APP + 3;
const WEASEL_IPC_PROCESS_KEY_EVENT: u32 = WM_APP + 4;
const WEASEL_IPC_SHUTDOWN_SERVER: u32 = WM_APP + 5;
const WEASEL_IPC_FOCUS_IN: u32 = WEASEL_IPC_SHUTDOWN_SERVER + 1;
const WEASEL_IPC_FOCUS_OUT: u32 = WM_APP + 7;
const WEASEL_IPC_UPDATE_INPUT_POS: u32 = WM_APP + 8;
const WEASEL_IPC_COMMIT_COMPOSITION: u32 = WM_APP + 11;
const WEASEL_IPC_CLEAR_COMPOSITION: u32 = WM_APP + 12;
const WEASEL_IPC_CHANGE_PAGE: u32 = WM_APP + 16;

// Private marker carried in FOCUS_IN.wParam.  Upstream 0.17.4 only logs the
// client_caps argument; it does not use it to mutate the composition.
const WAKE_MAGIC: u32 = 0x5242_494c; // "RBIL"
const PIPE_TIMEOUT_MS: u32 = 50;
const REFRESH_OPTION: &[u8] = b"_rime_bilingual_refresh\0";

const IMAGE_DOS_SIGNATURE: u16 = 0x5a4d;
const IMAGE_NT_SIGNATURE: u32 = 0x0000_4550;
const IMAGE_NT_OPTIONAL_HDR64_MAGIC: u16 = 0x020b;
const IMAGE_DIRECTORY_ENTRY_IMPORT: usize = 1;
const IMAGE_ORDINAL_FLAG64: u64 = 0x8000_0000_0000_0000;
const PAGE_READWRITE: u32 = 0x04;
const FILE_TYPE_PIPE: u32 = 0x0003;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, Eq, PartialEq)]
struct PipeMessage {
    msg: u32,
    w_param: u32,
    l_param: u32,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct WakeTarget {
    ipc_session: u32,
    foreground: isize,
}

#[derive(Clone, Copy, Default)]
struct ThreadPipeMessage {
    message: PipeMessage,
    refresh_pending: bool,
}

thread_local! {
    static THREAD_PIPE_MESSAGE: Cell<ThreadPipeMessage> = const {
        Cell::new(ThreadPipeMessage {
            message: PipeMessage { msg: 0, w_param: 0, l_param: 0 },
            refresh_pending: false,
        })
    };
}

static INSTALLED: AtomicBool = AtomicBool::new(false);
static ACTIVE_IPC_SESSION: AtomicU32 = AtomicU32::new(0);

type ReadFileFn =
    unsafe extern "system" fn(*mut c_void, *mut c_void, u32, *mut u32, *mut c_void) -> c_int;
type RimeGetStatusFn = unsafe extern "C" fn(usize, *mut RimeStatus) -> c_int;
type RimeFreeStatusFn = unsafe extern "C" fn(*mut RimeStatus) -> c_int;
type RimeSetOptionFn = unsafe extern "C" fn(usize, *const c_char, c_int);
type RimeGetOptionFn = unsafe extern "C" fn(usize, *const c_char) -> c_int;

static ORIGINAL_READ_FILE: OnceLock<ReadFileFn> = OnceLock::new();
static RIME_HOOKS: OnceLock<RimeHooks> = OnceLock::new();

#[derive(Clone, Copy)]
struct RimeHooks {
    get_status: RimeGetStatusFn,
    free_status: RimeFreeStatusFn,
    set_option: RimeSetOptionFn,
    get_option: RimeGetOptionFn,
}

#[repr(C)]
struct RimeStatus {
    data_size: c_int,
    schema_id: *mut c_char,
    schema_name: *mut c_char,
    is_disabled: c_int,
    is_composing: c_int,
    is_ascii_mode: c_int,
    is_full_shape: c_int,
    is_simplified: c_int,
    is_traditional: c_int,
    is_ascii_punct: c_int,
}

impl RimeStatus {
    fn initialized() -> Self {
        Self {
            data_size: (size_of::<Self>() - size_of::<c_int>()) as c_int,
            schema_id: ptr::null_mut(),
            schema_name: ptr::null_mut(),
            is_disabled: 0,
            is_composing: 0,
            is_ascii_mode: 0,
            is_full_shape: 0,
            is_simplified: 0,
            is_traditional: 0,
            is_ascii_punct: 0,
        }
    }
}

// Exact prefix of librime 1.13.1's RimeApi.  Both the installed rime.dll and
// this ABI are hash-pinned before the table is touched.
#[repr(C)]
struct RimeApiPrefix {
    data_size: c_int,
    setup: usize,
    set_notification_handler: usize,
    initialize: usize,
    finalize: usize,
    start_maintenance: usize,
    is_maintenance_mode: usize,
    join_maintenance_thread: usize,
    deployer_initialize: usize,
    prebuild: usize,
    deploy: usize,
    deploy_schema: usize,
    deploy_config_file: usize,
    sync_user_data: usize,
    create_session: usize,
    find_session: usize,
    destroy_session: usize,
    cleanup_stale_sessions: usize,
    cleanup_all_sessions: usize,
    process_key: usize,
    commit_composition: usize,
    clear_composition: usize,
    get_commit: usize,
    free_commit: usize,
    get_context: usize,
    free_context: usize,
    get_status: RimeGetStatusFn,
    free_status: RimeFreeStatusFn,
    set_option: RimeSetOptionFn,
    get_option: RimeGetOptionFn,
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetModuleHandleW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    fn GetModuleFileNameW(module: *mut c_void, path: *mut u16, size: u32) -> u32;
    fn GetFileType(file: *mut c_void) -> u32;
    fn VirtualProtect(
        address: *mut c_void,
        size: usize,
        new_protect: u32,
        old_protect: *mut u32,
    ) -> c_int;
    fn CallNamedPipeW(
        pipe_name: *const u16,
        input: *const c_void,
        input_size: u32,
        output: *mut c_void,
        output_size: u32,
        bytes_read: *mut u32,
        timeout_ms: u32,
    ) -> c_int;
    #[cfg(test)]
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
    #[cfg(test)]
    fn ReadFile(
        file: *mut c_void,
        buffer: *mut c_void,
        bytes_to_read: u32,
        bytes_read: *mut u32,
        overlapped: *mut c_void,
    ) -> c_int;
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn GetUserNameW(buffer: *mut u16, size: *mut u32) -> c_int;
}

pub(crate) fn install() -> Result<bool, &'static str> {
    if INSTALLED.load(Ordering::Acquire) {
        return Ok(true);
    }

    let exe = std::env::current_exe().map_err(|_| "weasel_mount_path")?;
    let is_weasel = exe
        .file_name()
        .and_then(|x| x.to_str())
        .is_some_and(|x| x.eq_ignore_ascii_case("WeaselServer.exe"));
    if !is_weasel {
        // Unit/integration test hosts are intentionally allowed to use the
        // bridge without installing process hooks.
        return Ok(false);
    }
    if !sha256_file(&exe)?.eq_ignore_ascii_case(EXPECTED_WEASEL_SERVER_SHA256) {
        return Err("weasel_abi_mismatch");
    }

    let rime_module = module_handle("rime.dll").ok_or("rime_module_missing")?;
    let rime_path = module_path(rime_module).ok_or("rime_module_path")?;
    if !sha256_file(&rime_path)?.eq_ignore_ascii_case(EXPECTED_RIME_SHA256) {
        return Err("rime_abi_mismatch");
    }

    unsafe {
        install_rime_hook(rime_module)?;
        if let Err(e) = install_read_file_hook() {
            restore_rime_hook();
            return Err(e);
        }
    }
    INSTALLED.store(true, Ordering::Release);
    Ok(true)
}

pub(crate) fn capture_wake_target() -> Option<WakeTarget> {
    if !INSTALLED.load(Ordering::Acquire) {
        return None;
    }
    let message = THREAD_PIPE_MESSAGE.with(Cell::get).message;
    if !matches!(
        message.msg,
        WEASEL_IPC_PROCESS_KEY_EVENT | WEASEL_IPC_CHANGE_PAGE
    ) || message.l_param == 0
    {
        return None;
    }
    if ACTIVE_IPC_SESSION.load(Ordering::Acquire) != message.l_param {
        return None;
    }
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.0.is_null() {
        return None;
    }
    Some(WakeTarget {
        ipc_session: message.l_param,
        foreground: foreground.0 as isize,
    })
}

pub(crate) fn wake(target: WakeTarget) -> bool {
    if !INSTALLED.load(Ordering::Acquire)
        || ACTIVE_IPC_SESSION.load(Ordering::Acquire) != target.ipc_session
    {
        return false;
    }
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.0.is_null() || foreground.0 as isize != target.foreground {
        return false;
    }
    let Some(pipe_name) = weasel_pipe_name() else {
        return false;
    };
    let message = PipeMessage {
        msg: WEASEL_IPC_FOCUS_IN,
        w_param: WAKE_MAGIC,
        l_param: target.ipc_session,
    };
    let mut response = 0u32;
    let mut bytes_read = 0u32;
    unsafe {
        CallNamedPipeW(
            pipe_name.as_ptr(),
            (&message as *const PipeMessage).cast(),
            size_of::<PipeMessage>() as u32,
            (&mut response as *mut u32).cast(),
            size_of::<u32>() as u32,
            &mut bytes_read,
            PIPE_TIMEOUT_MS,
        ) != 0
            && bytes_read == size_of::<u32>() as u32
    }
}

unsafe extern "system" fn hooked_read_file(
    file: *mut c_void,
    buffer: *mut c_void,
    bytes_to_read: u32,
    bytes_read: *mut u32,
    overlapped: *mut c_void,
) -> c_int {
    let Some(original) = ORIGINAL_READ_FILE.get().copied() else {
        return 0;
    };
    let ok = unsafe { original(file, buffer, bytes_to_read, bytes_read, overlapped) };
    if ok == 0
        || buffer.is_null()
        || bytes_read.is_null()
        || unsafe { *bytes_read } != size_of::<PipeMessage>() as u32
        || unsafe { GetFileType(file) } != FILE_TYPE_PIPE
    {
        return ok;
    }

    let mut message = unsafe { ptr::read_unaligned(buffer.cast::<PipeMessage>()) };
    if !is_weasel_ipc_command(message.msg) {
        return ok;
    }

    if message.msg == WEASEL_IPC_FOCUS_IN && message.w_param == WAKE_MAGIC {
        let accepted =
            message.l_param != 0 && ACTIVE_IPC_SESSION.load(Ordering::Acquire) == message.l_param;
        if accepted {
            THREAD_PIPE_MESSAGE.with(|slot| {
                slot.set(ThreadPipeMessage {
                    message,
                    refresh_pending: true,
                });
            });
        } else {
            // A focus change raced the worker's preflight check.  Replace the
            // wake with a harmless ECHO before upstream dispatch sees it.
            message = PipeMessage {
                msg: WEASEL_IPC_ECHO,
                w_param: 0,
                l_param: 0,
            };
            unsafe {
                ptr::write_unaligned(buffer.cast::<PipeMessage>(), message);
            }
            THREAD_PIPE_MESSAGE.with(|slot| slot.set(ThreadPipeMessage::default()));
        }
        return ok;
    }

    track_active_session(message);
    THREAD_PIPE_MESSAGE.with(|slot| {
        slot.set(ThreadPipeMessage {
            message,
            refresh_pending: false,
        });
    });
    ok
}

unsafe extern "C" fn hooked_get_status(session_id: usize, status: *mut RimeStatus) -> c_int {
    let Some(hooks) = RIME_HOOKS.get().copied() else {
        return 0;
    };
    let refresh_ipc = THREAD_PIPE_MESSAGE.with(|slot| {
        let mut state = slot.get();
        if !state.refresh_pending {
            return None;
        }
        state.refresh_pending = false;
        slot.set(state);
        Some(state.message.l_param)
    });

    if let Some(ipc_session) = refresh_ipc
        && ipc_session != 0
        && ACTIVE_IPC_SESSION.load(Ordering::Acquire) == ipc_session
    {
        let mut probe = RimeStatus::initialized();
        if unsafe { (hooks.get_status)(session_id, &mut probe) } != 0 {
            let composing = probe.is_composing != 0;
            unsafe {
                (hooks.free_status)(&mut probe);
            }
            if composing {
                let option = REFRESH_OPTION.as_ptr().cast::<c_char>();
                let next = if unsafe { (hooks.get_option)(session_id, option) } != 0 {
                    0
                } else {
                    1
                };
                // Weasel is already inside its serialized API handler here.
                // set_option therefore rebuilds the non-confirmed composition
                // before upstream _UpdateUI continues reading the context.
                unsafe {
                    (hooks.set_option)(session_id, option, next);
                }
            }
        }
    }
    unsafe { (hooks.get_status)(session_id, status) }
}

fn track_active_session(message: PipeMessage) {
    match message.msg {
        WEASEL_IPC_PROCESS_KEY_EVENT
        | WEASEL_IPC_FOCUS_IN
        | WEASEL_IPC_UPDATE_INPUT_POS
        | WEASEL_IPC_COMMIT_COMPOSITION
        | WEASEL_IPC_CLEAR_COMPOSITION
            if message.l_param != 0 =>
        {
            ACTIVE_IPC_SESSION.store(message.l_param, Ordering::Release);
        }
        WEASEL_IPC_FOCUS_OUT | WEASEL_IPC_END_SESSION => {
            let _ = ACTIVE_IPC_SESSION.compare_exchange(
                message.l_param,
                0,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
        _ => {}
    }
}

fn is_weasel_ipc_command(command: u32) -> bool {
    // 0.17.4 currently uses WM_APP+1 through WM_APP+16. Keep the parser
    // narrow so unrelated 12-byte pipe reads are never treated as Weasel IPC.
    (WM_APP + 1..=WM_APP + 16).contains(&command)
}

fn weasel_pipe_name() -> Option<Vec<u16>> {
    let mut buffer = [0u16; 256];
    let mut size = buffer.len() as u32;
    if unsafe { GetUserNameW(buffer.as_mut_ptr(), &mut size) } == 0 || size <= 1 {
        return None;
    }
    let username = String::from_utf16(&buffer[..size as usize - 1]).ok()?;
    Some(
        format!(r"\\.\pipe\{}\WeaselNamedPipe", username)
            .encode_utf16()
            .chain(Some(0))
            .collect(),
    )
}

unsafe fn install_rime_hook(module: *mut c_void) -> Result<(), &'static str> {
    let get_api = unsafe { GetProcAddress(module, c"rime_get_api".as_ptr()) };
    if get_api.is_null() {
        return Err("rime_api_missing");
    }
    let get_api: unsafe extern "C" fn() -> *mut RimeApiPrefix =
        unsafe { std::mem::transmute(get_api) };
    let api = unsafe { get_api() };
    if api.is_null() {
        return Err("rime_api_missing");
    }
    let required_data_size = size_of::<RimeApiPrefix>() - size_of::<c_int>();
    if unsafe { (*api).data_size } < required_data_size as c_int {
        return Err("rime_api_too_old");
    }
    let hooks = RimeHooks {
        get_status: unsafe { (*api).get_status },
        free_status: unsafe { (*api).free_status },
        set_option: unsafe { (*api).set_option },
        get_option: unsafe { (*api).get_option },
    };
    let _ = RIME_HOOKS.set(hooks);
    let slot = unsafe { &mut (*api).get_status as *mut RimeGetStatusFn };
    unsafe { patch_pointer(slot.cast(), hooked_get_status as *const () as usize) }
}

unsafe fn restore_rime_hook() {
    let Some(module) = module_handle("rime.dll") else {
        return;
    };
    let get_api = unsafe { GetProcAddress(module, c"rime_get_api".as_ptr()) };
    let Some(hooks) = RIME_HOOKS.get().copied() else {
        return;
    };
    if get_api.is_null() {
        return;
    }
    let get_api: unsafe extern "C" fn() -> *mut RimeApiPrefix =
        unsafe { std::mem::transmute(get_api) };
    let api = unsafe { get_api() };
    if api.is_null() {
        return;
    }
    let slot = unsafe { &mut (*api).get_status as *mut RimeGetStatusFn };
    let _ = unsafe { patch_pointer(slot.cast(), hooks.get_status as usize) };
}

unsafe fn install_read_file_hook() -> Result<(), &'static str> {
    let exe = unsafe { GetModuleHandleW(ptr::null()) };
    if exe.is_null() {
        return Err("weasel_module_missing");
    }
    let slot = unsafe { find_import_iat_slot(exe.cast::<u8>(), "KERNEL32.dll", "ReadFile") }?
        .ok_or("readfile_import_missing")?;
    let kernel = module_handle("kernel32.dll").ok_or("kernel32_missing")?;
    let read_file = unsafe { GetProcAddress(kernel, c"ReadFile".as_ptr()) };
    if read_file.is_null() || unsafe { *slot } != read_file as usize {
        return Err("readfile_import_mismatch");
    }
    let original: ReadFileFn = unsafe { std::mem::transmute(read_file) };
    let _ = ORIGINAL_READ_FILE.set(original);
    unsafe { patch_pointer(slot, hooked_read_file as *const () as usize) }
}

unsafe fn patch_pointer(slot: *mut usize, replacement: usize) -> Result<(), &'static str> {
    if slot.is_null() {
        return Err("hook_slot_missing");
    }
    let mut old = 0u32;
    if unsafe { VirtualProtect(slot.cast(), size_of::<usize>(), PAGE_READWRITE, &mut old) } == 0 {
        return Err("hook_protect_failed");
    }
    unsafe {
        ptr::write_volatile(slot, replacement);
    }
    let mut ignored = 0u32;
    if unsafe { VirtualProtect(slot.cast(), size_of::<usize>(), old, &mut ignored) } == 0 {
        return Err("hook_restore_protection_failed");
    }
    Ok(())
}

unsafe fn find_import_iat_slot(
    base: *mut u8,
    dll_name: &str,
    import_name: &str,
) -> Result<Option<*mut usize>, &'static str> {
    if base.is_null() || unsafe { read_u16(base, 0) } != Some(IMAGE_DOS_SIGNATURE) {
        return Err("invalid_pe");
    }
    let nt = unsafe { read_u32(base, 0x3c) }.ok_or("invalid_pe")? as usize;
    if unsafe { read_u32(base, nt) } != Some(IMAGE_NT_SIGNATURE) {
        return Err("invalid_pe");
    }
    let optional = nt.checked_add(24).ok_or("invalid_pe")?;
    if unsafe { read_u16(base, optional) } != Some(IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        return Err("unsupported_pe");
    }
    let image_size = unsafe { read_u32(base, optional + 56) }.ok_or("invalid_pe")? as usize;
    let directory = optional + 112 + IMAGE_DIRECTORY_ENTRY_IMPORT * 8;
    let import_rva = unsafe { read_u32(base, directory) }.ok_or("invalid_pe")? as usize;
    if import_rva == 0 || import_rva >= image_size {
        return Ok(None);
    }

    let mut descriptor = import_rva;
    loop {
        if descriptor
            .checked_add(20)
            .is_none_or(|end| end > image_size)
        {
            return Err("invalid_import_table");
        }
        let original_thunk = unsafe { read_u32(base, descriptor) }.ok_or("invalid_import_table")?;
        let name_rva = unsafe { read_u32(base, descriptor + 12) }.ok_or("invalid_import_table")?;
        let first_thunk =
            unsafe { read_u32(base, descriptor + 16) }.ok_or("invalid_import_table")?;
        if original_thunk == 0 && name_rva == 0 && first_thunk == 0 {
            break;
        }
        let name = unsafe { read_ascii_z(base, name_rva as usize, image_size, 128) }
            .ok_or("invalid_import_table")?;
        if name.eq_ignore_ascii_case(dll_name) {
            if original_thunk == 0 || first_thunk == 0 {
                return Err("unsupported_import_table");
            }
            let mut index = 0usize;
            loop {
                let oft = original_thunk as usize + index * 8;
                let iat = first_thunk as usize + index * 8;
                if oft.checked_add(8).is_none_or(|end| end > image_size)
                    || iat.checked_add(8).is_none_or(|end| end > image_size)
                {
                    return Err("invalid_import_table");
                }
                let thunk = unsafe { read_u64(base, oft) }.ok_or("invalid_import_table")?;
                if thunk == 0 {
                    break;
                }
                if thunk & IMAGE_ORDINAL_FLAG64 == 0 {
                    let import = unsafe { read_ascii_z(base, thunk as usize + 2, image_size, 128) }
                        .ok_or("invalid_import_table")?;
                    if import == import_name {
                        return Ok(Some(unsafe { base.add(iat).cast::<usize>() }));
                    }
                }
                index += 1;
            }
            return Ok(None);
        }
        descriptor += 20;
    }
    Ok(None)
}

unsafe fn read_u16(base: *const u8, offset: usize) -> Option<u16> {
    (!base.is_null()).then(|| unsafe { ptr::read_unaligned(base.add(offset).cast::<u16>()) })
}
unsafe fn read_u32(base: *const u8, offset: usize) -> Option<u32> {
    (!base.is_null()).then(|| unsafe { ptr::read_unaligned(base.add(offset).cast::<u32>()) })
}
unsafe fn read_u64(base: *const u8, offset: usize) -> Option<u64> {
    (!base.is_null()).then(|| unsafe { ptr::read_unaligned(base.add(offset).cast::<u64>()) })
}
unsafe fn read_ascii_z(
    base: *const u8,
    offset: usize,
    image_size: usize,
    max_len: usize,
) -> Option<String> {
    if base.is_null() || offset >= image_size {
        return None;
    }
    let mut bytes = Vec::new();
    for i in 0..max_len {
        let at = offset.checked_add(i)?;
        if at >= image_size {
            return None;
        }
        let byte = unsafe { *base.add(at) };
        if byte == 0 {
            return String::from_utf8(bytes).ok();
        }
        if !byte.is_ascii() {
            return None;
        }
        bytes.push(byte);
    }
    None
}

fn module_handle(name: &str) -> Option<*mut c_void> {
    let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    let module = unsafe { GetModuleHandleW(wide.as_ptr()) };
    (!module.is_null()).then_some(module)
}

fn module_path(module: *mut c_void) -> Option<std::path::PathBuf> {
    let mut buffer = vec![0u16; 32_768];
    let len = unsafe { GetModuleFileNameW(module, buffer.as_mut_ptr(), buffer.len() as u32) };
    if len == 0 || len as usize >= buffer.len() {
        return None;
    }
    Some(std::path::PathBuf::from(String::from_utf16_lossy(
        &buffer[..len as usize],
    )))
}

fn sha256_file(path: &std::path::Path) -> Result<String, &'static str> {
    let mut file = File::open(path).map_err(|_| "hash_open_failed")?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|_| "hash_read_failed")?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02X}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pipe_message_is_exact_upstream_wire_size() {
        assert_eq!(size_of::<PipeMessage>(), 12);
        assert_eq!(WEASEL_IPC_PROCESS_KEY_EVENT, WM_APP + 4);
        assert_eq!(WEASEL_IPC_SHUTDOWN_SERVER, WM_APP + 5);
        assert_eq!(WEASEL_IPC_FOCUS_IN, WM_APP + 6);
        assert_eq!(WEASEL_IPC_FOCUS_OUT, WM_APP + 7);
        assert_eq!(WEASEL_IPC_UPDATE_INPUT_POS, WM_APP + 8);
        assert_eq!(WEASEL_IPC_COMMIT_COMPOSITION, WM_APP + 11);
        assert_eq!(WEASEL_IPC_CLEAR_COMPOSITION, WM_APP + 12);
        assert_eq!(WEASEL_IPC_CHANGE_PAGE, WM_APP + 16);
    }

    #[test]
    fn active_tracking_is_fail_closed() {
        ACTIVE_IPC_SESSION.store(0, Ordering::Release);
        track_active_session(PipeMessage {
            msg: WEASEL_IPC_PROCESS_KEY_EVENT,
            w_param: 0,
            l_param: 123,
        });
        assert_eq!(ACTIVE_IPC_SESSION.load(Ordering::Acquire), 123);
        track_active_session(PipeMessage {
            msg: WEASEL_IPC_FOCUS_OUT,
            w_param: 0,
            l_param: 456,
        });
        assert_eq!(ACTIVE_IPC_SESSION.load(Ordering::Acquire), 123);
        track_active_session(PipeMessage {
            msg: WEASEL_IPC_FOCUS_OUT,
            w_param: 0,
            l_param: 123,
        });
        assert_eq!(ACTIVE_IPC_SESSION.load(Ordering::Acquire), 0);
    }

    #[test]
    fn pe_parser_finds_live_test_process_readfile_iat() {
        let _force_import = ReadFile as *const ();
        let exe = unsafe { GetModuleHandleW(ptr::null()) };
        assert!(!exe.is_null());
        let slot = unsafe { find_import_iat_slot(exe.cast(), "KERNEL32.dll", "ReadFile") }
            .expect("test process must be a valid PE image")
            .expect("test process must import ReadFile");
        let kernel = module_handle("kernel32.dll").expect("kernel32 must be loaded");
        let proc = unsafe { GetProcAddress(kernel, c"ReadFile".as_ptr()) };
        assert!(!proc.is_null());
        assert_eq!(unsafe { *slot }, proc as usize);
    }

    #[test]
    fn rime_api_prefix_matches_installed_1_13_1() {
        let path: Vec<u16> = r"C:\Program Files\Rime\weasel-0.17.4\rime.dll"
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let module = unsafe { LoadLibraryW(path.as_ptr()) };
        assert!(!module.is_null(), "installed rime.dll must load");
        let get_api = unsafe { GetProcAddress(module, c"rime_get_api".as_ptr()) };
        assert!(!get_api.is_null(), "rime_get_api must be exported");
        let get_api: unsafe extern "C" fn() -> *mut RimeApiPrefix =
            unsafe { std::mem::transmute(get_api) };
        let api = unsafe { get_api() };
        assert!(!api.is_null());
        let required = size_of::<RimeApiPrefix>() - size_of::<c_int>();
        assert!(unsafe { (*api).data_size } >= required as c_int);
        assert_ne!(unsafe { (*api).get_status as usize }, 0);
        assert_ne!(unsafe { (*api).free_status as usize }, 0);
        assert_ne!(unsafe { (*api).set_option as usize }, 0);
        assert_ne!(unsafe { (*api).get_option as usize }, 0);
    }
}
