use libloading::Library;
use sha2::{Digest, Sha256};
use std::env;
use std::ffi::{CString, c_char, c_int};
use std::fs::File;
use std::io::Read;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::ptr;

const EXPECTED_RIME_SHA256: &str =
    "2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B";
const DEFAULT_WEASEL_DIR: &str = r"C:\Program Files\Rime\weasel-0.17.4";
const DISTRIBUTION_NAME: &str = "小狼毫";
const DISTRIBUTION_CODE_NAME: &str = "Weasel";
const DISTRIBUTION_VERSION: &str = "0.17.4";
const APP_NAME: &str = "rime.weasel";

type RimeBool = c_int;
type RimeSetup = unsafe extern "C" fn(*mut RimeTraits);
type RimeDeployerInitialize = unsafe extern "C" fn(*mut RimeTraits);
type RimeDeploySchema = unsafe extern "C" fn(*const c_char) -> RimeBool;
type RimeFinalize = unsafe extern "C" fn();

#[repr(C)]
struct RimeTraits {
    data_size: c_int,
    shared_data_dir: *const c_char,
    user_data_dir: *const c_char,
    distribution_name: *const c_char,
    distribution_code_name: *const c_char,
    distribution_version: *const c_char,
    app_name: *const c_char,
    modules: *const *const c_char,
    min_log_level: c_int,
    log_dir: *const c_char,
    prebuilt_data_dir: *const c_char,
    staging_dir: *const c_char,
}

struct OwnedTraits {
    shared_data_dir: CString,
    user_data_dir: CString,
    distribution_name: CString,
    distribution_code_name: CString,
    distribution_version: CString,
    app_name: CString,
    log_dir: CString,
    traits: RimeTraits,
}

impl OwnedTraits {
    fn new(shared_data_dir: &Path, user_data_dir: &Path) -> Result<Self, String> {
        let shared_data_dir = path_cstring(shared_data_dir)?;
        let user_data_dir = path_cstring(user_data_dir)?;
        let distribution_name = cstring(DISTRIBUTION_NAME, "distribution name")?;
        let distribution_code_name = cstring(DISTRIBUTION_CODE_NAME, "distribution code name")?;
        let distribution_version = cstring(DISTRIBUTION_VERSION, "distribution version")?;
        let app_name = cstring(APP_NAME, "application name")?;
        // Empty log_dir matches librime's documented "stderr only" mode and
        // keeps this one-shot utility from creating another persistent log tree.
        let log_dir = cstring("", "log directory")?;

        let mut owned = Self {
            shared_data_dir,
            user_data_dir,
            distribution_name,
            distribution_code_name,
            distribution_version,
            app_name,
            log_dir,
            traits: RimeTraits {
                data_size: 0,
                shared_data_dir: ptr::null(),
                user_data_dir: ptr::null(),
                distribution_name: ptr::null(),
                distribution_code_name: ptr::null(),
                distribution_version: ptr::null(),
                app_name: ptr::null(),
                modules: ptr::null(),
                min_log_level: 2,
                log_dir: ptr::null(),
                prebuilt_data_dir: ptr::null(),
                staging_dir: ptr::null(),
            },
        };
        owned.traits.data_size = (size_of::<RimeTraits>() - size_of::<c_int>()) as c_int;
        owned.traits.shared_data_dir = owned.shared_data_dir.as_ptr();
        owned.traits.user_data_dir = owned.user_data_dir.as_ptr();
        owned.traits.distribution_name = owned.distribution_name.as_ptr();
        owned.traits.distribution_code_name = owned.distribution_code_name.as_ptr();
        owned.traits.distribution_version = owned.distribution_version.as_ptr();
        owned.traits.app_name = owned.app_name.as_ptr();
        owned.traits.log_dir = owned.log_dir.as_ptr();
        // Weasel 0.17.4 explicitly sets prebuilt_data_dir = shared_data_dir.
        owned.traits.prebuilt_data_dir = owned.shared_data_dir.as_ptr();
        Ok(owned)
    }
}

#[derive(Debug, Clone)]
struct Options {
    rime_dll: PathBuf,
    shared_data_dir: PathBuf,
    user_data_dir: PathBuf,
    dry_run: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("RimeBilingualDeploy: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let options = parse_args(env::args().skip(1))?;
    validate_options(&options)?;
    if options.dry_run {
        println!(
            "RimeBilingualDeploy validation passed: rime='{}', shared='{}', user='{}', schema='{}'",
            options.rime_dll.display(),
            options.shared_data_dir.display(),
            options.user_data_dir.display(),
            options.user_data_dir.join("rime_ice.schema.yaml").display()
        );
        return Ok(());
    }

    deploy(&options)?;
    println!("RimeBilingualDeploy completed successfully.");
    Ok(())
}

fn default_options() -> Result<Options, String> {
    let weasel_dir = PathBuf::from(DEFAULT_WEASEL_DIR);
    let appdata = env::var_os("APPDATA").ok_or("APPDATA is unavailable")?;
    Ok(Options {
        rime_dll: weasel_dir.join("rime.dll"),
        shared_data_dir: weasel_dir.join("data"),
        user_data_dir: PathBuf::from(appdata).join("Rime"),
        dry_run: false,
    })
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = default_options()?;
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--rime-dll" => options.rime_dll = PathBuf::from(next_value(&mut args, &arg)?),
            "--shared-data-dir" => {
                options.shared_data_dir = PathBuf::from(next_value(&mut args, &arg)?)
            }
            "--user-data-dir" => {
                options.user_data_dir = PathBuf::from(next_value(&mut args, &arg)?)
            }
            "--dry-run" => options.dry_run = true,
            "--help" | "-h" => {
                println!(
                    "Usage: RimeBilingualDeploy [--rime-dll PATH] [--shared-data-dir PATH] [--user-data-dir PATH] [--dry-run]"
                );
                std::process::exit(0);
            }
            _ => return Err(format!("unknown argument: {arg}")),
        }
    }
    Ok(options)
}

fn next_value(
    args: &mut std::iter::Peekable<impl Iterator<Item = String>>,
    flag: &str,
) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn validate_options(options: &Options) -> Result<(), String> {
    if !options.rime_dll.is_file() {
        return Err(format!("rime.dll is missing: {}", options.rime_dll.display()));
    }
    if !options.shared_data_dir.is_dir() {
        return Err(format!(
            "shared data directory is missing: {}",
            options.shared_data_dir.display()
        ));
    }
    if !options.user_data_dir.is_dir() {
        return Err(format!(
            "user data directory is missing: {}",
            options.user_data_dir.display()
        ));
    }
    let schema_path = options.user_data_dir.join("rime_ice.schema.yaml");
    if !schema_path.is_file() {
        return Err(format!(
            "rime_ice schema source is missing: {}",
            schema_path.display()
        ));
    }
    let actual = sha256_file(&options.rime_dll)?;
    if !actual.eq_ignore_ascii_case(EXPECTED_RIME_SHA256) {
        return Err(format!(
            "unsupported rime.dll SHA-256: expected {EXPECTED_RIME_SHA256}, got {actual}"
        ));
    }
    Ok(())
}

fn deploy(options: &Options) -> Result<(), String> {
    // The absolute path is hash-pinned before loading. libloading keeps the
    // module alive until every function call below has completed.
    let library = unsafe { Library::new(&options.rime_dll) }
        .map_err(|e| format!("failed to load pinned rime.dll: {e}"))?;
    let setup = unsafe { library.get::<RimeSetup>(b"RimeSetup\0") }
        .map_err(|e| format!("RimeSetup export unavailable: {e}"))?;
    let deployer_initialize = unsafe {
        library.get::<RimeDeployerInitialize>(b"RimeDeployerInitialize\0")
    }
    .map_err(|e| format!("RimeDeployerInitialize export unavailable: {e}"))?;
    let deploy_schema = unsafe { library.get::<RimeDeploySchema>(b"RimeDeploySchema\0") }
        .map_err(|e| format!("RimeDeploySchema export unavailable: {e}"))?;
    let finalize = unsafe { library.get::<RimeFinalize>(b"RimeFinalize\0") }
        .map_err(|e| format!("RimeFinalize export unavailable: {e}"))?;

    let mut traits = OwnedTraits::new(&options.shared_data_dir, &options.user_data_dir)?;
    let schema_path = path_cstring(&options.user_data_dir.join("rime_ice.schema.yaml"))?;

    unsafe {
        setup(&mut traits.traits);
        // This mirrors WeaselDeployer 0.17.4: Setup receives traits, while
        // DeployerInitialize(NULL) loads the standard deployer module set.
        deployer_initialize(ptr::null_mut());
    }

    let result = if unsafe { deploy_schema(schema_path.as_ptr()) } != 0 {
        Ok(())
    } else {
        Err("RimeDeploySchema(rime_ice.schema.yaml) reported failure".to_string())
    };

    unsafe { finalize() };
    result
}

fn cstring(value: &str, label: &str) -> Result<CString, String> {
    CString::new(value).map_err(|_| format!("{label} contains an embedded NUL"))
}

fn path_cstring(path: &Path) -> Result<CString, String> {
    let text = path
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", path.display()))?;
    cstring(text, "path")
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|e| format!("cannot hash {}: {e}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:X}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rime_traits_data_size_matches_rime_struct_init() {
        let expected = size_of::<RimeTraits>() - size_of::<c_int>();
        assert!(expected > 0);
        assert_eq!(expected % size_of::<*const std::ffi::c_void>(), 4);
    }

    #[test]
    fn pinned_rime_hash_is_uppercase_sha256() {
        assert_eq!(EXPECTED_RIME_SHA256.len(), 64);
        assert!(EXPECTED_RIME_SHA256
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)));
    }
}

