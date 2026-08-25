use std::{env, net::SocketAddr, path::PathBuf, process::ExitCode, time::Duration};

use rime_translate_helper::{AppState, Config, router};
use tokio::net::TcpListener;

fn usage() -> &'static str {
    "RimeTranslateHelper\n\nUsage:\n  RimeTranslateHelper.exe [--bind 127.0.0.1:18081] [--llama-endpoint http://127.0.0.1:18080/v1/chat/completions] [--model MODEL] [--timeout-ms 30000] [--cache-path PATH] [--max-concurrency 2]\n\nEnvironment fallbacks:\n  RIME_BILINGUAL_BIND\n  RIME_BILINGUAL_LLAMA_ENDPOINT\n  RIME_BILINGUAL_MODEL\n  RIME_BILINGUAL_TIMEOUT_MS\n  RIME_BILINGUAL_CACHE_PATH\n  RIME_BILINGUAL_MAX_CONCURRENCY"
}

fn value(args: &[String], flag: &str, env_name: &str, default: &str) -> Result<String, String> {
    let mut found = None;
    let mut index = 0;
    while index < args.len() {
        if args[index] == flag {
            index += 1;
            let supplied = args
                .get(index)
                .ok_or_else(|| format!("missing value for {flag}"))?;
            found = Some(supplied.clone());
        }
        index += 1;
    }
    Ok(found
        .or_else(|| env::var(env_name).ok())
        .unwrap_or_else(|| default.to_string()))
}

fn parse_config(args: &[String]) -> Result<Config, String> {
    let allowed = [
        "--bind",
        "--llama-endpoint",
        "--model",
        "--timeout-ms",
        "--cache-path",
        "--max-concurrency",
    ];
    let mut index = 0;
    while index < args.len() {
        if !allowed.contains(&args[index].as_str()) {
            return Err(format!("unknown argument: {}", args[index]));
        }
        index += 2;
    }
    let bind: SocketAddr = value(args, "--bind", "RIME_BILINGUAL_BIND", "127.0.0.1:18081")?
        .parse()
        .map_err(|_| "bind must be an IP address and port".to_string())?;
    let endpoint = value(
        args,
        "--llama-endpoint",
        "RIME_BILINGUAL_LLAMA_ENDPOINT",
        "http://127.0.0.1:18080/v1/chat/completions",
    )?;
    let model = value(
        args,
        "--model",
        "RIME_BILINGUAL_MODEL",
        "gemma-3-1b-it-qat-q4_0",
    )?;
    let timeout_ms: u64 = value(args, "--timeout-ms", "RIME_BILINGUAL_TIMEOUT_MS", "30000")?
        .parse()
        .map_err(|_| "timeout must be an integer number of milliseconds".to_string())?;
    let config = Config::new(bind, &endpoint, model, Duration::from_millis(timeout_ms))?;
    let default_cache_path = config.cache_path.to_string_lossy().into_owned();
    let cache_path = value(
        args,
        "--cache-path",
        "RIME_BILINGUAL_CACHE_PATH",
        &default_cache_path,
    )?;
    let max_concurrency: usize = value(
        args,
        "--max-concurrency",
        "RIME_BILINGUAL_MAX_CONCURRENCY",
        "2",
    )?
    .parse()
    .map_err(|_| "max concurrency must be an integer".to_string())?;
    config
        .with_cache_path(PathBuf::from(cache_path))?
        .with_max_concurrency(max_concurrency)
}

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{}", usage());
        return ExitCode::SUCCESS;
    }
    let config = match parse_config(&args) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("configuration error: {error}\n\n{}", usage());
            return ExitCode::from(2);
        }
    };
    let bind = config.bind;
    let state = match AppState::new(config) {
        Ok(state) => state,
        Err(error) => {
            eprintln!("configuration error: {error}");
            return ExitCode::from(2);
        }
    };
    let listener = match TcpListener::bind(bind).await {
        Ok(listener) => listener,
        Err(_) => {
            eprintln!("failed to bind helper loopback listener");
            return ExitCode::FAILURE;
        }
    };
    eprintln!("event=helper_started bind={bind}");
    if axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .is_err()
    {
        eprintln!("helper server stopped unexpectedly");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
