use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use futures_util::StreamExt;
use reqwest::Url;
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, Semaphore, oneshot};

pub const PROTOCOL_VERSION: u32 = 3;
pub const MAX_REQUEST_BODY_BYTES: usize = 32 * 1024;
pub const MAX_REQUEST_ID_BYTES: usize = 128;
pub const MAX_CANDIDATES: usize = 20;
pub const MAX_CANDIDATE_BYTES: usize = 256;
pub const MAX_TRANSLATION_BYTES: usize = 256;
pub const MAX_CONTEXT_BYTES: usize = 512;
pub const MAX_CONTEXT_CHARS: usize = 120;
pub const MAX_UPSTREAM_BODY_BYTES: usize = 64 * 1024;
pub const CACHE_APPLICATION_ID: i64 = 1_380_075_852;
pub const CACHE_SCHEMA_VERSION: i64 = 1;
pub const SYSTEM_PROMPT: &str = "You are a Chinese-English dictionary gloss engine for one IME candidate. Exactly one numbered candidate is provided per model call. Read the exact Chinese characters carefully and do not substitute a homophone, a similar-looking word, or a different word with the same pronunciation. First identify whether the whole candidate is an established lexical item, technical term, idiom, or proper name; treat it as one lexical unit before considering individual characters. Prefer the conventional dictionary meaning over a character-by-character guess. For scientific or technical terms, use the standard English term. For longer compounds, preserve an important head word or suffix such as a state or a type of wine when that meaning is actually present. Translate by meaning, not by sound: never output pinyin, romanization, or phonetic spelling unless the candidate is clearly a proper name with a standard English romanization; for established proper names, use that standard name rather than a literal character translation. Prefer the shortest natural dictionary gloss, usually one to three English words. If CONTEXT is present, use it only to disambiguate this candidate. If CONTEXT is empty, use the candidate's most common lexical meaning. Return ASCII English only and never copy Chinese characters. Your entire response must be one JSON object with exactly one field named translations whose value is an array containing exactly one string. Do not use Markdown, code fences, labels, explanations, or extra fields.";

const SOURCE_LANGUAGE: &str = "zh";
const TARGET_LANGUAGE: &str = "en";
const TRANSLATION_MODE: &str = "literal";
const CONTEXT_CACHE_VERSION: &str = "context-v5";
const CACHE_BUSY_TIMEOUT: Duration = Duration::from_millis(50);
const MAX_INFLIGHT_BATCHES: usize = 32;

#[derive(Clone, Debug)]
pub struct Config {
    pub bind: SocketAddr,
    pub llama_endpoint: Url,
    pub model: String,
    pub timeout: Duration,
    pub cache_path: PathBuf,
    pub max_concurrency: usize,
}

impl Config {
    pub fn new(
        bind: SocketAddr,
        llama_endpoint: &str,
        model: String,
        timeout: Duration,
    ) -> Result<Self, String> {
        if bind.ip() != IpAddr::from([127, 0, 0, 1]) {
            return Err("helper bind address must be 127.0.0.1".into());
        }
        if model.trim().is_empty() || model.len() > 128 {
            return Err("model identity must contain 1 to 128 bytes".into());
        }
        if timeout.is_zero() || timeout > Duration::from_secs(120) {
            return Err("timeout must be between 1 ms and 120 seconds".into());
        }
        let endpoint = Url::parse(llama_endpoint)
            .map_err(|_| "llama endpoint must be a valid URL".to_string())?;
        if endpoint.scheme() != "http" {
            return Err("llama endpoint must use http".into());
        }
        if !endpoint.username().is_empty() || endpoint.password().is_some() {
            return Err("llama endpoint must not contain credentials".into());
        }
        if endpoint.query().is_some() || endpoint.fragment().is_some() {
            return Err("llama endpoint must not contain query or fragment".into());
        }
        let host = endpoint
            .host_str()
            .ok_or_else(|| "llama endpoint must contain a host".to_string())?;
        if host != "127.0.0.1" && !host.eq_ignore_ascii_case("localhost") {
            return Err("llama endpoint host must be 127.0.0.1 or localhost".into());
        }
        let port = endpoint
            .port_or_known_default()
            .ok_or_else(|| "llama endpoint must contain a port".to_string())?;
        let resolved: Vec<_> = (host, port)
            .to_socket_addrs()
            .map_err(|_| "llama endpoint host could not be resolved".to_string())?
            .collect();
        if resolved.is_empty() || resolved.iter().any(|address| !address.ip().is_loopback()) {
            return Err("llama endpoint must resolve only to loopback addresses".into());
        }
        if endpoint.path() != "/v1/chat/completions" {
            return Err("llama endpoint path must be /v1/chat/completions".into());
        }
        Ok(Self {
            bind,
            llama_endpoint: endpoint,
            model,
            timeout,
            cache_path: default_cache_path()?,
            max_concurrency: 2,
        })
    }

    pub fn with_cache_path(mut self, cache_path: PathBuf) -> Result<Self, String> {
        if cache_path.as_os_str().is_empty() {
            return Err("cache path must not be empty".into());
        }
        self.cache_path = cache_path;
        Ok(self)
    }

    pub fn with_max_concurrency(mut self, value: usize) -> Result<Self, String> {
        if !(1..=16).contains(&value) {
            return Err("max concurrency must be between 1 and 16".into());
        }
        self.max_concurrency = value;
        Ok(self)
    }

    fn health_url(&self) -> Url {
        let mut url = self.llama_endpoint.clone();
        url.set_path("/health");
        url
    }
}

fn default_cache_path() -> Result<PathBuf, String> {
    let app_data = std::env::var_os("APPDATA")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "APPDATA is required to locate the translation cache".to_string())?;
    Ok(PathBuf::from(app_data)
        .join("Rime")
        .join("rime-bilingual")
        .join("translations.db"))
}

#[derive(Clone, Debug)]
struct HelperError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
    retryable: bool,
}

impl HelperError {
    fn new(status: StatusCode, code: &'static str, message: &'static str, retryable: bool) -> Self {
        Self {
            status,
            code,
            message,
            retryable,
        }
    }
    fn invalid_request() -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "request did not match a supported protocol",
            false,
        )
    }
    fn cache_unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "CACHE_UNAVAILABLE",
            "translation cache is unavailable",
            true,
        )
    }
    fn unavailable() -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "MODEL_UNAVAILABLE",
            "local model service is unavailable",
            true,
        )
    }
    fn timeout() -> Self {
        Self::new(
            StatusCode::GATEWAY_TIMEOUT,
            "MODEL_TIMEOUT",
            "local model request timed out",
            true,
        )
    }
    fn invalid_output() -> Self {
        Self::new(
            StatusCode::BAD_GATEWAY,
            "MODEL_OUTPUT_INVALID",
            "model output did not match the requested batch",
            true,
        )
    }
}

type SharedResult = Result<Arc<Vec<String>>, HelperError>;
type Waiters = HashMap<String, Vec<oneshot::Sender<SharedResult>>>;

#[derive(Clone)]
pub struct AppState {
    config: Config,
    client: reqwest::Client,
    inflight: Arc<Mutex<Waiters>>,
    inference_slots: Arc<Semaphore>,
}

impl AppState {
    pub fn new(config: Config) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .connect_timeout(config.timeout)
            .timeout(config.timeout)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|_| "failed to construct HTTP client".to_string())?;
        Ok(Self {
            inference_slots: Arc::new(Semaphore::new(config.max_concurrency)),
            config,
            client,
            inflight: Arc::new(Mutex::new(HashMap::new())),
        })
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/translate", post(translate))
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BODY_BYTES))
        .with_state(Arc::new(state))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireRequest {
    protocol_version: u32,
    request_id: String,
    context: String,
    candidates: Vec<String>,
    generation: Option<u64>,
    candidate_fingerprint: Option<String>,
    page_start: Option<u32>,
}

/// Protocol v1 request shape retained for existing Rust callers and fixtures.
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TranslateRequest {
    pub protocol_version: u32,
    pub request_id: String,
    pub context: String,
    pub candidates: Vec<String>,
}

#[derive(Debug)]
struct ValidRequest {
    protocol_version: u32,
    request_id: String,
    context: String,
    candidates: Vec<String>,
    generation: u64,
    candidate_fingerprint: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TranslateResponseV1 {
    pub protocol_version: u32,
    pub request_id: String,
    pub translations: Vec<String>,
    pub model: String,
    pub elapsed_ms: u64,
}

/// Backward-compatible name for the protocol v1 response shape.
pub type TranslateResponse = TranslateResponseV1;

#[derive(Debug, Serialize, Deserialize)]
pub struct TranslateResponseV2 {
    pub protocol_version: u32,
    pub request_id: String,
    pub generation: u64,
    pub candidate_fingerprint: String,
    pub translations: Vec<String>,
    pub model: String,
    pub source: String,
    pub elapsed_ms: u64,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    protocol_version: u32,
    status: &'static str,
    llama_ready: bool,
    endpoint: String,
    model: String,
}

#[derive(Debug, Serialize)]
struct ErrorEnvelope<'a> {
    protocol_version: u32,
    request_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    generation: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    candidate_fingerprint: Option<&'a str>,
    error: ErrorBody,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    code: &'static str,
    message: &'static str,
    retryable: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TranslationSource {
    Cache,
    Mixed,
    Model,
}

impl TranslationSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Cache => "cache",
            Self::Mixed => "mixed",
            Self::Model => "model",
        }
    }
}

async fn health(State(state): State<Arc<AppState>>) -> Json<HealthResponse> {
    let ready = state
        .client
        .get(state.config.health_url())
        .send()
        .await
        .is_ok_and(|response| response.status().is_success());
    Json(HealthResponse {
        protocol_version: PROTOCOL_VERSION,
        status: "ok",
        llama_ready: ready,
        endpoint: public_endpoint(&state.config.llama_endpoint),
        model: state.config.model.clone(),
    })
}

fn public_endpoint(endpoint: &Url) -> String {
    format!(
        "{}://{}:{}{}",
        endpoint.scheme(),
        endpoint.host_str().unwrap_or("loopback"),
        endpoint.port_or_known_default().unwrap_or(80),
        endpoint.path()
    )
}

async fn translate(
    State(state): State<Arc<AppState>>,
    payload: Result<Json<WireRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let wire = match payload {
        Ok(Json(request)) => request,
        Err(_) => return error_response(2, "", 0, "", HelperError::invalid_request()),
    };
    let version = wire.protocol_version;
    let request_id = wire.request_id.clone();
    let generation = wire.generation.unwrap_or(0);
    let fingerprint = wire.candidate_fingerprint.clone().unwrap_or_default();
    let request = match validate_request(wire) {
        Ok(request) => request,
        Err(error) => return error_response(version, &request_id, generation, &fingerprint, error),
    };

    let started = Instant::now();
    match translate_cached(&state, &request.context, &request.candidates).await {
        Ok((translations, source, hit_count, miss_count)) => {
            let elapsed = elapsed_ms(started);
            eprintln!(
                "timestamp_ms={} event=translate_ok request_id={} batch_size={} cache_hits={} misses={} model={} source={} elapsed_ms={}",
                timestamp_ms(),
                safe_log_id(&request.request_id),
                request.candidates.len(),
                hit_count,
                miss_count,
                safe_log_id(&state.config.model),
                source.as_str(),
                elapsed
            );
            if request.protocol_version == 1 {
                Json(TranslateResponseV1 {
                    protocol_version: 1,
                    request_id: request.request_id,
                    translations,
                    model: state.config.model.clone(),
                    elapsed_ms: elapsed,
                })
                .into_response()
            } else {
                Json(TranslateResponseV2 {
                    protocol_version: request.protocol_version,
                    request_id: request.request_id,
                    generation: request.generation,
                    candidate_fingerprint: request.candidate_fingerprint,
                    translations,
                    model: state.config.model.clone(),
                    source: source.as_str().into(),
                    elapsed_ms: elapsed,
                })
                .into_response()
            }
        }
        Err(error) => {
            eprintln!(
                "timestamp_ms={} event=translate_error request_id={} batch_size={} model={} error_code={} elapsed_ms={}",
                timestamp_ms(),
                safe_log_id(&request.request_id),
                request.candidates.len(),
                safe_log_id(&state.config.model),
                error.code,
                elapsed_ms(started)
            );
            error_response(
                request.protocol_version,
                &request.request_id,
                request.generation,
                &request.candidate_fingerprint,
                error,
            )
        }
    }
}

fn validate_request(request: WireRequest) -> Result<ValidRequest, HelperError> {
    let id_valid = !request.request_id.is_empty()
        && request.request_id.len() <= MAX_REQUEST_ID_BYTES
        && request
            .request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    let candidates_valid = !request.candidates.is_empty()
        && request.candidates.len() <= MAX_CANDIDATES
        && request
            .candidates
            .iter()
            .all(|candidate| valid_text(candidate, MAX_CANDIDATE_BYTES));
    if !id_valid || !candidates_valid {
        return Err(HelperError::invalid_request());
    }
    let normalized_context = normalize_context(&request.context)?;
    match request.protocol_version {
        1 if request.context.is_empty()
            && request.generation.is_none()
            && request.candidate_fingerprint.is_none()
            && request.page_start.is_none() =>
        {
            Ok(ValidRequest {
                protocol_version: 1,
                request_id: request.request_id,
                context: String::new(),
                candidates: request.candidates,
                generation: 0,
                candidate_fingerprint: String::new(),
            })
        }
        2 if request.context.is_empty()
            && request.generation.is_some()
            && request.page_start.is_some()
            && request.candidate_fingerprint.as_ref().is_some_and(|value| {
                value.len() == 64
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            }) =>
        {
            Ok(ValidRequest {
                protocol_version: 2,
                request_id: request.request_id,
                context: String::new(),
                candidates: request.candidates,
                generation: request.generation.unwrap_or(0),
                candidate_fingerprint: request.candidate_fingerprint.unwrap_or_default(),
            })
        }
        3 if request.generation.is_some()
            && request.page_start.is_some()
            && request.candidate_fingerprint.as_ref().is_some_and(|value| {
                value.len() == 64
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            }) =>
        {
            Ok(ValidRequest {
                protocol_version: 3,
                request_id: request.request_id,
                context: normalized_context,
                candidates: request.candidates,
                generation: request.generation.unwrap_or(0),
                candidate_fingerprint: request.candidate_fingerprint.unwrap_or_default(),
            })
        }
        _ => Err(HelperError::invalid_request()),
    }
}

fn normalize_context(value: &str) -> Result<String, HelperError> {
    let mut normalized = String::with_capacity(value.len().min(MAX_CONTEXT_BYTES));
    let mut pending_space = false;
    for character in value.chars() {
        if character.is_control() && !character.is_whitespace() {
            return Err(HelperError::invalid_request());
        }
        if character.is_whitespace() {
            pending_space = !normalized.is_empty();
            continue;
        }
        if pending_space {
            normalized.push(' ');
            pending_space = false;
        }
        normalized.push(character);
        if normalized.len() > MAX_CONTEXT_BYTES || normalized.chars().count() > MAX_CONTEXT_CHARS {
            return Err(HelperError::invalid_request());
        }
    }
    Ok(normalized)
}

fn valid_text(value: &str, max_bytes: usize) -> bool {
    !value.trim().is_empty() && value.len() <= max_bytes && !value.chars().any(char::is_control)
}

fn valid_translation(value: &str) -> bool {
    valid_text(value, MAX_TRANSLATION_BYTES)
        && value.is_ascii()
        && value.bytes().any(|byte| byte.is_ascii_alphabetic())
}

fn safe_log_id(value: &str) -> String {
    value
        .chars()
        .take(128)
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn timestamp_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

async fn translate_cached(
    state: &Arc<AppState>,
    context: &str,
    candidates: &[String],
) -> Result<(Vec<String>, TranslationSource, usize, usize), HelperError> {
    let translation_mode = translation_mode_for(&state.config.model, context);
    let unique = ordered_unique(candidates);
    let cached = cache_lookup(state, unique.clone(), translation_mode.clone()).await?;
    let misses: Vec<String> = unique
        .iter()
        .filter(|text| !cached.contains_key(*text))
        .cloned()
        .collect();
    let hit_count = candidates
        .iter()
        .filter(|candidate| cached.contains_key(*candidate))
        .count();
    let miss_count = candidates.len() - hit_count;
    let mut translations = cached;
    if !misses.is_empty() {
        let inferred = infer_and_cache_deduplicated(
            state,
            context.to_string(),
            translation_mode,
            misses.clone(),
        )
        .await?;
        if inferred.len() != misses.len() {
            return Err(HelperError::invalid_output());
        }
        translations.extend(misses.into_iter().zip(inferred.iter().cloned()));
    }
    let ordered = candidates
        .iter()
        .map(|candidate| {
            translations
                .get(candidate)
                .cloned()
                .ok_or_else(HelperError::invalid_output)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let source = if miss_count == 0 {
        TranslationSource::Cache
    } else if hit_count == 0 {
        TranslationSource::Model
    } else {
        TranslationSource::Mixed
    };
    Ok((ordered, source, hit_count, miss_count))
}

fn ordered_unique(candidates: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    candidates
        .iter()
        .filter(|candidate| seen.insert((*candidate).clone()))
        .cloned()
        .collect()
}

async fn cache_lookup(
    state: &AppState,
    candidates: Vec<String>,
    translation_mode: String,
) -> Result<HashMap<String, String>, HelperError> {
    let path = state.config.cache_path.clone();
    let work = tokio::task::spawn_blocking(move || {
        cache_lookup_mode_blocking(&path, &candidates, &translation_mode)
    });
    tokio::time::timeout(state.config.timeout, work)
        .await
        .map_err(|_| HelperError::cache_unavailable())?
        .map_err(|_| HelperError::cache_unavailable())?
}

fn open_validated_cache(path: &Path) -> Result<Connection, HelperError> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| HelperError::cache_unavailable())?;
    connection
        .busy_timeout(CACHE_BUSY_TIMEOUT)
        .map_err(|_| HelperError::cache_unavailable())?;
    connection
        .execute_batch("BEGIN IMMEDIATE; ROLLBACK;")
        .map_err(|_| HelperError::cache_unavailable())?;
    let integrity: String = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .map_err(|_| HelperError::cache_unavailable())?;
    if integrity != "ok" {
        return Err(HelperError::cache_unavailable());
    }
    let application_id: i64 = connection
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|_| HelperError::cache_unavailable())?;
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| HelperError::cache_unavailable())?;
    if application_id != CACHE_APPLICATION_ID || user_version != CACHE_SCHEMA_VERSION {
        return Err(HelperError::cache_unavailable());
    }
    validate_table(
        &connection,
        "translations",
        &[
            ("source_text", "TEXT", 1, 1),
            ("source_language", "TEXT", 1, 2),
            ("target_language", "TEXT", 1, 3),
            ("translation_mode", "TEXT", 1, 4),
            ("translated_text", "TEXT", 1, 0),
            ("source", "TEXT", 1, 0),
            ("updated_at_utc", "TEXT", 1, 0),
        ],
    )?;
    validate_table(
        &connection,
        "cache_meta",
        &[
            ("id", "INTEGER", 1, 1),
            ("revision", "INTEGER", 1, 0),
            ("updated_at_utc", "TEXT", 1, 0),
        ],
    )?;
    let translations_sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='translations'",
            [],
            |row| row.get(0),
        )
        .map_err(|_| HelperError::cache_unavailable())?;
    let meta_rows: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM cache_meta WHERE id=1 AND revision >= 0",
            [],
            |row| row.get(0),
        )
        .map_err(|_| HelperError::cache_unavailable())?;
    if !translations_sql
        .to_ascii_uppercase()
        .contains("WITHOUT ROWID")
        || meta_rows != 1
    {
        return Err(HelperError::cache_unavailable());
    }
    Ok(connection)
}

fn validate_table(
    connection: &Connection,
    table: &str,
    expected: &[(&str, &str, i64, i64)],
) -> Result<(), HelperError> {
    let sql = match table {
        "translations" => "PRAGMA table_info('translations')",
        "cache_meta" => "PRAGMA table_info('cache_meta')",
        _ => return Err(HelperError::cache_unavailable()),
    };
    let mut statement = connection
        .prepare(sql)
        .map_err(|_| HelperError::cache_unavailable())?;
    let actual = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(5)?,
            ))
        })
        .map_err(|_| HelperError::cache_unavailable())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| HelperError::cache_unavailable())?;
    if actual.len() != expected.len()
        || actual.iter().zip(expected).any(
            |(
                (name, kind, not_null, primary_key),
                (want_name, want_kind, want_not_null, want_pk),
            )| {
                name != want_name
                    || !kind.eq_ignore_ascii_case(want_kind)
                    || not_null != want_not_null
                    || primary_key != want_pk
            },
        )
    {
        return Err(HelperError::cache_unavailable());
    }
    Ok(())
}

#[cfg(test)]
fn cache_lookup_blocking(
    path: &Path,
    candidates: &[String],
) -> Result<HashMap<String, String>, HelperError> {
    cache_lookup_mode_blocking(path, candidates, TRANSLATION_MODE)
}

fn cache_lookup_mode_blocking(
    path: &Path,
    candidates: &[String],
    translation_mode: &str,
) -> Result<HashMap<String, String>, HelperError> {
    let connection = open_validated_cache(path)?;
    let mut statement = connection.prepare_cached(
        "SELECT translated_text FROM translations WHERE source_text=?1 AND source_language=?2 AND target_language=?3 AND translation_mode=?4",
    ).map_err(|_| HelperError::cache_unavailable())?;
    let mut results = HashMap::new();
    for candidate in candidates {
        let translation: Option<String> = statement
            .query_row(
                params![
                    candidate,
                    SOURCE_LANGUAGE,
                    TARGET_LANGUAGE,
                    translation_mode
                ],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| HelperError::cache_unavailable())?;
        if let Some(translation) = translation {
            if !valid_translation(&translation) {
                return Err(HelperError::cache_unavailable());
            }
            results.insert(candidate.clone(), translation);
        }
    }
    Ok(results)
}

async fn infer_and_cache_deduplicated(
    state: &Arc<AppState>,
    context: String,
    translation_mode: String,
    misses: Vec<String>,
) -> SharedResult {
    let key = dedup_key(&state.config.model, &translation_mode, &misses);
    let (sender, receiver) = oneshot::channel();
    let mut inflight = state.inflight.lock().await;
    if let Some(waiters) = inflight.get_mut(&key) {
        waiters.push(sender);
        drop(inflight);
        return receiver
            .await
            .unwrap_or_else(|_| Err(HelperError::unavailable()));
    }
    if inflight.len() >= MAX_INFLIGHT_BATCHES {
        return Err(HelperError::unavailable());
    }
    inflight.insert(key.clone(), vec![sender]);
    drop(inflight);

    let task_state = Arc::clone(state);
    tokio::spawn(async move {
        let timeout = task_state.config.timeout;
        let result = tokio::time::timeout(timeout, async {
            let _permit = task_state
                .inference_slots
                .acquire()
                .await
                .map_err(|_| HelperError::unavailable())?;
            let translations = translate_batch(&task_state, &context, &misses).await?;
            cache_upsert(&task_state, translation_mode, misses, translations.clone()).await?;
            Ok::<_, HelperError>(Arc::new(translations))
        })
        .await
        .unwrap_or_else(|_| Err(HelperError::timeout()));
        let waiters = task_state
            .inflight
            .lock()
            .await
            .remove(&key)
            .unwrap_or_default();
        for waiter in waiters {
            let _ = waiter.send(result.clone());
        }
    });
    receiver
        .await
        .unwrap_or_else(|_| Err(HelperError::unavailable()))
}

fn dedup_key(model: &str, mode: &str, misses: &[String]) -> String {
    let mut digest = Sha256::new();
    digest.update(b"RBIL-HELPER-DEDUP-V1\0");
    hash_frame(&mut digest, model.as_bytes());
    hash_frame(&mut digest, mode.as_bytes());
    digest.update((misses.len() as u32).to_le_bytes());
    for miss in misses {
        hash_frame(&mut digest, miss.as_bytes());
    }
    format!("{:x}", digest.finalize())
}

fn hash_frame(digest: &mut Sha256, bytes: &[u8]) {
    digest.update((bytes.len() as u32).to_le_bytes());
    digest.update(bytes);
}

fn translation_mode_for(model: &str, context: &str) -> String {
    if context.is_empty() {
        return TRANSLATION_MODE.to_string();
    }
    let mut digest = Sha256::new();
    digest.update(b"RBIL-CONTEXT-CACHE-V1\0");
    hash_frame(&mut digest, model.as_bytes());
    hash_frame(&mut digest, SYSTEM_PROMPT.as_bytes());
    hash_frame(&mut digest, context.as_bytes());
    format!("{}:{:x}", CONTEXT_CACHE_VERSION, digest.finalize())
}

async fn cache_upsert(
    state: &AppState,
    translation_mode: String,
    candidates: Vec<String>,
    translations: Vec<String>,
) -> Result<(), HelperError> {
    let path = state.config.cache_path.clone();
    let model = state.config.model.clone();
    let work = tokio::task::spawn_blocking(move || {
        cache_upsert_blocking(&path, &model, &translation_mode, &candidates, &translations)
    });
    tokio::time::timeout(state.config.timeout, work)
        .await
        .map_err(|_| HelperError::cache_unavailable())?
        .map_err(|_| HelperError::cache_unavailable())?
}

fn cache_upsert_blocking(
    path: &Path,
    model: &str,
    translation_mode: &str,
    candidates: &[String],
    translations: &[String],
) -> Result<(), HelperError> {
    if candidates.len() != translations.len()
        || translations.iter().any(|item| !valid_translation(item))
    {
        return Err(HelperError::invalid_output());
    }
    let mut connection = open_validated_cache(path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| HelperError::cache_unavailable())?;
    {
        let mut statement = transaction.prepare_cached(
            "INSERT INTO translations (source_text,source_language,target_language,translation_mode,translated_text,source,updated_at_utc) VALUES (?1,?2,?3,?4,?5,?6,strftime('%Y-%m-%dT%H:%M:%fZ','now')) ON CONFLICT(source_text,source_language,target_language,translation_mode) DO UPDATE SET translated_text=excluded.translated_text,source=excluded.source,updated_at_utc=excluded.updated_at_utc",
        ).map_err(|_| HelperError::cache_unavailable())?;
        let source = format!("model:{}", safe_log_id(model));
        for (candidate, translation) in candidates.iter().zip(translations) {
            statement
                .execute(params![
                    candidate,
                    SOURCE_LANGUAGE,
                    TARGET_LANGUAGE,
                    translation_mode,
                    translation,
                    source
                ])
                .map_err(|_| HelperError::cache_unavailable())?;
        }
    }
    let changed = transaction.execute(
        "UPDATE cache_meta SET revision=revision+1, updated_at_utc=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=1", [],
    ).map_err(|_| HelperError::cache_unavailable())?;
    if changed != 1 {
        return Err(HelperError::cache_unavailable());
    }
    transaction
        .commit()
        .map_err(|_| HelperError::cache_unavailable())
}

async fn translate_batch(
    state: &AppState,
    context: &str,
    candidates: &[String],
) -> Result<Vec<String>, HelperError> {
    // Keep the Helper HTTP contract page-batched, but isolate each model
    // inference so semantically similar IME candidates cannot bleed into one
    // another inside a small local model's attention window.  The outer
    // infer_and_cache_deduplicated timeout still bounds the whole page, and
    // cache_upsert runs only after every singleton has succeeded.
    let mut translations = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        translations.push(translate_single_candidate(state, context, candidate).await?);
    }
    Ok(translations)
}

async fn translate_single_candidate(
    state: &AppState,
    context: &str,
    candidate: &str,
) -> Result<String, HelperError> {
    let mut user_payload = String::with_capacity(
        context.len() + candidate.len() + 64,
    );
    user_payload.push_str("CONTEXT: ");
    if context.is_empty() {
        user_payload.push_str("(none)");
    } else {
        user_payload.push_str(context);
    }
    user_payload.push_str("\nCANDIDATES:\n");
    user_payload.push_str("0: ");
    user_payload.push_str(candidate);
    user_payload.push('\n');
    let body = json!({
        "model": state.config.model, "temperature": 0.1, "max_tokens": 256, "stream": false,
        "grammar": translation_grammar(1),
        "messages": [
            {"role":"system","content":SYSTEM_PROMPT},
            {"role":"user","content":user_payload}
        ]
    });
    let response = state
        .client
        .post(state.config.llama_endpoint.clone())
        .json(&body)
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                HelperError::timeout()
            } else {
                HelperError::unavailable()
            }
        })?;
    if !response.status().is_success() {
        return Err(HelperError::unavailable());
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_UPSTREAM_BODY_BYTES as u64)
    {
        return Err(HelperError::invalid_output());
    }
    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| {
            if error.is_timeout() {
                HelperError::timeout()
            } else {
                HelperError::unavailable()
            }
        })?;
        if bytes.len().saturating_add(chunk.len()) > MAX_UPSTREAM_BODY_BYTES {
            return Err(HelperError::invalid_output());
        }
        bytes.extend_from_slice(&chunk);
    }
    let completion: Value =
        serde_json::from_slice(&bytes).map_err(|_| HelperError::invalid_output())?;
    let content = completion
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(|item| item.get("message"))
        .and_then(|item| item.get("content"))
        .and_then(Value::as_str)
        .ok_or_else(HelperError::invalid_output)?;
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct ModelOutput {
        translations: Vec<String>,
    }
    let translations = serde_json::from_str::<ModelOutput>(content)
        .map_err(|_| HelperError::invalid_output())?
        .translations;
    if translations.len() != 1
        || translations.iter().any(|item| !valid_translation(item))
    {
        return Err(HelperError::invalid_output());
    }
    Ok(translations.into_iter().next().unwrap())
}

fn translation_grammar(batch_size: usize) -> String {
    let items = std::iter::repeat_n("string", batch_size)
        .collect::<Vec<_>>()
        .join(" ws \",\" ws ");
    format!(
        "root ::= object\nobject ::= \"{{\" ws \"\\\"translations\\\"\" ws \":\" ws array ws \"}}\"\narray ::= \"[\" ws {items} ws \"]\"\nstring ::= \"\\\"\" chars \"\\\"\"\nchars ::= [A-Za-z0-9 .,!?;:'()_/+&-]+\nws ::= [ \\t\\n\\r]*\n"
    )
}

fn error_response(
    version: u32,
    request_id: &str,
    generation: u64,
    fingerprint: &str,
    error: HelperError,
) -> Response {
    let stateful = matches!(version, 2 | 3);
    let response_version = match version {
        1 => 1,
        2 => 2,
        _ => 3,
    };
    let body = Json(ErrorEnvelope {
        protocol_version: response_version,
        request_id,
        generation: stateful.then_some(generation),
        candidate_fingerprint: stateful.then_some(fingerprint),
        error: ErrorBody {
            code: error.code,
            message: error.message,
            retryable: error.retryable,
        },
    });
    (error.status, body).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, extract::State, http::Request, routing::post};
    use std::sync::{
        Mutex as StdMutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tempfile::TempDir;
    use tokio::{net::TcpListener, time::sleep};
    use tower::ServiceExt;

    #[derive(Clone)]
    struct MockState {
        calls: Arc<AtomicUsize>,
        requests: Arc<StdMutex<Vec<Value>>>,
        translations: Arc<HashMap<String, String>>,
        delay: Duration,
    }

    async fn mock_server(
        translations: &[(&str, &str)],
        delay: Duration,
    ) -> (String, Arc<AtomicUsize>, Arc<StdMutex<Vec<Value>>>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let requests = Arc::new(StdMutex::new(Vec::new()));
        let state = MockState {
            calls: calls.clone(),
            requests: requests.clone(),
            translations: Arc::new(
                translations
                    .iter()
                    .map(|(a, b)| ((*a).into(), (*b).into()))
                    .collect(),
            ),
            delay,
        };
        let app = Router::new().route("/v1/chat/completions", post(|State(state): State<MockState>, Json(request): Json<Value>| async move {
            state.calls.fetch_add(1, Ordering::SeqCst); state.requests.lock().unwrap().push(request.clone()); sleep(state.delay).await;
            let input = request["messages"][1]["content"].as_str().unwrap();
            let candidates: Vec<String> = input
                .lines()
                .skip_while(|line| *line != "CANDIDATES:")
                .skip(1)
                .filter_map(|line| line.split_once(": ").map(|(_, text)| text.to_string()))
                .collect();
            let values: Vec<String> = candidates.iter().map(|candidate| state.translations.get(candidate).cloned().unwrap_or_else(|| "?".into())).collect();
            Json(json!({"choices":[{"message":{"content":json!({"translations":values}).to_string()}}]}))
        })).with_state(state);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (format!("http://{address}"), calls, requests)
    }

    async fn raw_server(status: StatusCode, body: Value) -> (String, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let route_calls = calls.clone();
        let app = Router::new().route(
            "/v1/chat/completions",
            post(move || {
                let route_calls = route_calls.clone();
                let body = body.clone();
                async move {
                    route_calls.fetch_add(1, Ordering::SeqCst);
                    (status, Json(body))
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (format!("http://{address}"), calls)
    }

    fn init_cache(path: &Path) {
        Connection::open(path)
            .unwrap()
            .execute_batch(include_str!("../../data/cache_schema.sql"))
            .unwrap();
    }
    fn cache_put(path: &Path, zh: &str, en: &str) {
        Connection::open(path).unwrap().execute("INSERT INTO translations VALUES (?1,'zh','en','literal',?2,'fixture','2026-01-01T00:00:00.000Z')", params![zh,en]).unwrap();
    }
    fn state(endpoint: &str, timeout: Duration, db: PathBuf) -> AppState {
        let config = Config::new(
            "127.0.0.1:0".parse().unwrap(),
            &format!("{endpoint}/v1/chat/completions"),
            "test-model".into(),
            timeout,
        )
        .unwrap()
        .with_cache_path(db)
        .unwrap();
        AppState::new(config).unwrap()
    }
    async fn request(app: Router, body: Value) -> (StatusCode, Value) {
        let response = app
            .oneshot(
                Request::post("/translate")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), MAX_REQUEST_BODY_BYTES)
            .await
            .unwrap();
        (status, serde_json::from_slice(&bytes).unwrap())
    }
    fn v1(candidates: Value) -> Value {
        json!({"protocol_version":1,"request_id":"test-1","context":"","candidates":candidates})
    }
    fn v2(id: &str, generation: u64, candidates: Value) -> Value {
        json!({"protocol_version":2,"request_id":id,"generation":generation,"candidate_fingerprint":"a".repeat(64),"page_start":0,"context":"","candidates":candidates})
    }
    fn v3(id: &str, generation: u64, context: &str, candidates: Value) -> Value {
        json!({"protocol_version":3,"request_id":id,"generation":generation,"candidate_fingerprint":"a".repeat(64),"page_start":0,"context":context,"candidates":candidates})
    }

    #[test]
    fn config_and_request_limits_fail_closed() {
        for endpoint in [
            "https://127.0.0.1:8080/v1/chat/completions",
            "http://0.0.0.0:8080/v1/chat/completions",
            "http://example.com:8080/v1/chat/completions",
            "http://127.0.0.1:8080/wrong",
        ] {
            assert!(
                Config::new(
                    "127.0.0.1:18081".parse().unwrap(),
                    endpoint,
                    "model".into(),
                    Duration::from_secs(1),
                )
                .is_err()
            );
        }
        let invalid = WireRequest {
            protocol_version: 2,
            request_id: "bad id".into(),
            context: String::new(),
            candidates: vec!["我".into()],
            generation: Some(1),
            candidate_fingerprint: Some("a".repeat(64)),
            page_start: Some(0),
        };
        assert!(validate_request(invalid).is_err());
        let uppercase = WireRequest {
            protocol_version: 2,
            request_id: "valid-id".into(),
            context: String::new(),
            candidates: vec!["我".into()],
            generation: Some(1),
            candidate_fingerprint: Some("A".repeat(64)),
            page_start: Some(0),
        };
        assert!(validate_request(uppercase).is_err());
    }

    #[tokio::test]
    async fn v1_shape_remains_compatible_and_writes_cache() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        let (endpoint, calls, _) = mock_server(&[("我", "I"), ("你", "You")], Duration::ZERO).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db.clone())),
            v1(json!(["我", "你"])),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["protocol_version"], 1);
        assert_eq!(body["translations"], json!(["I", "You"]));
        assert!(body.get("source").is_none());
        assert!(body.get("generation").is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            cache_lookup_blocking(&db, &["我".into()]).unwrap()["我"],
            "I"
        );
        let revision: i64 = Connection::open(&db)
            .unwrap()
            .query_row("SELECT revision FROM cache_meta WHERE id=1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(revision, 1);
    }

    #[tokio::test]
    async fn v2_full_cache_skips_model_and_exactly_echoes() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        cache_put(&db, "今天", "Today");
        let (endpoint, calls, _) = mock_server(&[], Duration::ZERO).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db)),
            v2("rime-42", 42, json!(["今天", "今天"])),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["request_id"], "rime-42");
        assert_eq!(body["generation"], 42);
        assert_eq!(body["candidate_fingerprint"], "a".repeat(64));
        assert_eq!(body["translations"], json!(["Today", "Today"]));
        assert_eq!(body["source"], "cache");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn v2_still_rejects_nonempty_context() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        let (endpoint, calls, _) = mock_server(&[("作業", "homework")], Duration::ZERO).await;
        let mut body = v2("legacy-context", 2, json!(["作業"]));
        body["context"] = json!("老師說明天要交");
        let (status, response) =
            request(router(state(&endpoint, Duration::from_secs(1), db)), body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(response["protocol_version"], 2);
        assert_eq!(response["error"]["code"], "INVALID_REQUEST");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn v3_normalizes_context_sends_it_to_model_and_isolates_cache() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        let (endpoint, calls, requests) =
            mock_server(&[("作業", "homework")], Duration::ZERO).await;
        let app = router(state(&endpoint, Duration::from_secs(1), db.clone()));

        let first = request(
            app.clone(),
            v3("ctx-a1", 10, "  老師說  明天\n要交  ", json!(["作業"])),
        )
        .await;
        assert_eq!(first.0, StatusCode::OK);
        assert_eq!(first.1["protocol_version"], 3);
        assert_eq!(first.1["translations"], json!(["homework"]));
        assert_eq!(first.1["source"], "model");
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let second = request(
            app.clone(),
            v3("ctx-a2", 11, "老師說 明天 要交", json!(["作業"])),
        )
        .await;
        assert_eq!(second.0, StatusCode::OK);
        assert_eq!(second.1["source"], "cache");
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let third = request(app, v3("ctx-b", 12, "這份工作算是", json!(["作業"]))).await;
        assert_eq!(third.0, StatusCode::OK);
        assert_eq!(third.1["source"], "model");
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        let captured = requests.lock().unwrap();
        let first_payload = captured[0]["messages"][1]["content"].as_str().unwrap();
        assert!(first_payload.starts_with("CONTEXT: 老師說 明天 要交\nCANDIDATES:\n"));
        assert!(first_payload.contains("0: 作業\n"));

        let connection = Connection::open(&db).unwrap();
        let contextual_rows: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM translations WHERE source_text='作業' AND translation_mode LIKE 'context-v5:%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(contextual_rows, 2);
        let leaked_context: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM translations WHERE translation_mode LIKE '%老師%' OR translation_mode LIKE '%工作%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(leaked_context, 0);
    }

    #[test]
    fn v3_context_limits_and_normalization_fail_closed() {
        let valid = WireRequest {
            protocol_version: 3,
            request_id: "ctx".into(),
            context: "  這次  考試\n考得  ".into(),
            candidates: vec!["還好".into()],
            generation: Some(1),
            candidate_fingerprint: Some("a".repeat(64)),
            page_start: Some(0),
        };
        let normalized = validate_request(valid).unwrap();
        assert_eq!(normalized.context, "這次 考試 考得");

        let too_long = WireRequest {
            protocol_version: 3,
            request_id: "ctx-long".into(),
            context: "中".repeat(MAX_CONTEXT_CHARS + 1),
            candidates: vec!["還好".into()],
            generation: Some(1),
            candidate_fingerprint: Some("a".repeat(64)),
            page_start: Some(0),
        };
        assert!(validate_request(too_long).is_err());

        let control = WireRequest {
            protocol_version: 3,
            request_id: "ctx-control".into(),
            context: "前文\u{0001}".into(),
            candidates: vec!["還好".into()],
            generation: Some(1),
            candidate_fingerprint: Some("a".repeat(64)),
            page_start: Some(0),
        };
        assert!(validate_request(control).is_err());
    }

    #[tokio::test]
    async fn partial_cache_infers_unique_misses_independently_and_recombines() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        cache_put(&db, "我", "I");
        let (endpoint, calls, requests) =
            mock_server(&[("你", "You"), ("今天", "Today")], Duration::ZERO).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db)),
            v2("mixed", 3, json!(["我", "你", "你", "今天", "我"])),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            body["translations"],
            json!(["I", "You", "You", "Today", "I"])
        );
        assert_eq!(body["source"], "mixed");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let captured = requests.lock().unwrap();
        assert_eq!(captured.len(), 2);
        let sent = captured
            .iter()
            .map(|request| {
                let payload = request["messages"][1]["content"].as_str().unwrap();
                let candidates = payload
                    .lines()
                    .skip_while(|line| *line != "CANDIDATES:")
                    .skip(1)
                    .filter_map(|line| line.split_once(": ").map(|(_, text)| text.to_string()))
                    .collect::<Vec<_>>();
                assert_eq!(candidates.len(), 1);
                candidates[0].clone()
            })
            .collect::<Vec<_>>();
        assert_eq!(sent, vec!["你", "今天"]);
    }

    #[tokio::test]
    async fn concurrent_identical_misses_are_deduplicated() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        let (endpoint, calls, _) =
            mock_server(&[("學校", "School")], Duration::from_millis(80)).await;
        let app = router(state(&endpoint, Duration::from_secs(2), db));
        let (a, b) = tokio::join!(
            request(app.clone(), v2("a", 7, json!(["學校"]))),
            request(app, v2("b", 8, json!(["學校"])))
        );
        assert_eq!(a.0, StatusCode::OK);
        assert_eq!(b.0, StatusCode::OK);
        assert_eq!(a.1["generation"], 7);
        assert_eq!(b.1["generation"], 8);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn unavailable_cache_fails_before_model() {
        let temp = TempDir::new().unwrap();
        let (endpoint, calls, _) = mock_server(&[("我", "I")], Duration::ZERO).await;
        for (index, db) in [
            temp.path().join("missing.db"),
            temp.path().join("corrupt.db"),
        ]
        .into_iter()
        .enumerate()
        {
            if index == 1 {
                std::fs::write(&db, b"not sqlite").unwrap();
            }
            let (status, body) = request(
                router(state(&endpoint, Duration::from_secs(1), db)),
                v2("cache", 1, json!(["我"])),
            )
            .await;
            assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(body["error"]["code"], "CACHE_UNAVAILABLE");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn schema_mismatch_fails_before_model() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("mismatch.db");
        init_cache(&db);
        Connection::open(&db)
            .unwrap()
            .pragma_update(None, "user_version", 99)
            .unwrap();
        let (endpoint, calls, _) = mock_server(&[("我", "I")], Duration::ZERO).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db)),
            v2("schema", 1, json!(["我"])),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "CACHE_UNAVAILABLE");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn busy_cache_fails_before_model() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("busy.db");
        init_cache(&db);
        let lock = Connection::open(&db).unwrap();
        lock.execute_batch("BEGIN IMMEDIATE").unwrap();
        let (endpoint, calls, _) = mock_server(&[("我", "I")], Duration::ZERO).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db)),
            v2("busy", 1, json!(["我"])),
        )
        .await;
        lock.execute_batch("ROLLBACK").unwrap();
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "CACHE_UNAVAILABLE");
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn timeout_does_not_write_cache() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("t.db");
        init_cache(&db);
        let (endpoint, _, _) = mock_server(&[("我", "I")], Duration::from_millis(100)).await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_millis(10), db.clone())),
            v2("timeout", 1, json!(["我"])),
        )
        .await;
        assert_eq!(status, StatusCode::GATEWAY_TIMEOUT);
        assert_eq!(body["error"]["code"], "MODEL_TIMEOUT");
        assert!(
            cache_lookup_blocking(&db, &["我".into()])
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn invalid_model_output_echoes_v2_error_and_writes_nothing() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("invalid-output.db");
        init_cache(&db);
        let (endpoint, calls) = raw_server(
            StatusCode::OK,
            json!({"choices":[{"message":{"content":"{\"translations\":[\"I\",\"extra\"]}"}}]}),
        )
        .await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db.clone())),
            v2("invalid-output", 77, json!(["我"])),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_GATEWAY);
        assert_eq!(body["protocol_version"], 2);
        assert_eq!(body["request_id"], "invalid-output");
        assert_eq!(body["generation"], 77);
        assert_eq!(body["candidate_fingerprint"], "a".repeat(64));
        assert_eq!(body["error"]["code"], "MODEL_OUTPUT_INVALID");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(
            cache_lookup_blocking(&db, &["我".into()])
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn v3_rejects_non_english_model_output_and_does_not_cache_it() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("non-english.db");
        init_cache(&db);
        let (endpoint, calls) = raw_server(
            StatusCode::OK,
            json!({"choices":[{"message":{"content":"{\"translations\":[\"不錯\"]}"}}]}),
        )
        .await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db.clone())),
            v3("non-english", 88, "這次考試考得", json!(["不錯"])),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_GATEWAY);
        assert_eq!(body["protocol_version"], 3);
        assert_eq!(body["generation"], 88);
        assert_eq!(body["error"]["code"], "MODEL_OUTPUT_INVALID");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let count: i64 = Connection::open(&db)
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM translations WHERE source_text='不錯'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn upstream_failure_is_model_unavailable() {
        let temp = TempDir::new().unwrap();
        let db = temp.path().join("unavailable.db");
        init_cache(&db);
        let (endpoint, _) = raw_server(
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({"secret":"not logged"}),
        )
        .await;
        let (status, body) = request(
            router(state(&endpoint, Duration::from_secs(1), db)),
            v1(json!(["我"])),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["protocol_version"], 1);
        assert!(body.get("generation").is_none());
        assert_eq!(body["error"]["code"], "MODEL_UNAVAILABLE");
    }

    #[test]
    fn framed_dedup_hash_preserves_boundaries_and_order() {
        assert_ne!(
            dedup_key("ab", "c", &["d".into()]),
            dedup_key("a", "bc", &["d".into()])
        );
        assert_ne!(
            dedup_key("m", "literal", &["a".into(), "b".into()]),
            dedup_key("m", "literal", &["b".into(), "a".into()])
        );
    }

    #[test]
    fn translation_output_must_be_ascii_english() {
        assert!(valid_translation("not bad"));
        assert!(valid_translation("I'll pass"));
        assert!(!valid_translation("不錯"));
        assert!(!valid_translation("幸好"));
        assert!(!valid_translation("123"));
        assert!(SYSTEM_PROMPT.contains("never output pinyin"));
        assert!(SYSTEM_PROMPT.contains("Exactly one numbered candidate"));
        let grammar = translation_grammar(2);
        assert!(grammar.contains("[A-Za-z0-9 .,!?;:'()_/+&-]+"));
    }
}
