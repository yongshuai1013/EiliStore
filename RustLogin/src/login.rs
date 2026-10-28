// "Their Rust login": Apparition's sign-in flow (core/src/lib.rs `sign_in`
// + core/src/claimed_platform.rs), re-implemented over this crate's local
// ADI engine instead of a remote v3 anisette server.
//
// The login itself is isideload 0.5.0 (Apparition's vendored copy in
// vendor/isideload, MIT, Copyright nab138 / Illixion for the vendored
// patches): GrandSlam SRP + 2FA + the Xcode token, unmodified. What is
// ours is only the AnisetteProvider: it serves OTPs from the in-process
// ADI engine (see adi.rs) and claims Android, because the anisette is
// made by Apple Music's Android libraries — the same reasoning as
// Apparition's ClaimedPlatform wrapper, except the claim is intrinsic to
// this provider (there is no server to ask), so no wrapper is needed.
//
// The claim follows Apparition's constants verbatim (claimed_platform.rs):
// sign-in claims Android; once signed in, the Xcode token and developer
// requests claim a Mac (`after_sign_in`), or Apple answers -80046. Their
// -22411 dance (an Android-claimed sign-in gets no 2FA step and no token
// until a pushed code is checked) is ported as well.

use std::ffi::{CStr, c_char, c_void};
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use http::{HeaderMap, HeaderValue};
use isideload::anisette::{AnisetteClientInfo, AnisetteData, AnisetteDataGenerator, AnisetteDataResponse, AnisetteProvider};
use isideload::auth::apple_account::{AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::auth::grandslam::GrandSlam;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::app_groups::{AppGroup, AppGroupsApi};
use isideload::dev::app_ids::{AppId, AppIdsApi};
use isideload::dev::certificates::CertificatesApi;
use isideload::dev::device_type::{dev_url, DeveloperDeviceType};
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use plist::Dictionary;
use plist_macro::plist;
use rootcause::prelude::*;
use sha2::{Digest, Sha256};
use tokio::sync::RwLock;

use crate::{fail, with_engine, write_error};

// MARK: - Diagnostics (stage markers + panic capture)
//
// The login runs across an FFI boundary, where a Rust panic aborts the
// process before Swift can see anything. Stage markers and the panic
// hook write to a file that survives the crash; the app sets its path
// with `apparition_set_diagnostic_log` and shows the contents on the
// next launch. `apparition_login*` also catch_unwinds, turning a panic
// in the sign-in flow into a normal error return whenever possible.

static DIAG_PATH: std::sync::Mutex<Option<std::path::PathBuf>> = std::sync::Mutex::new(None);
static HOOK_ONCE: std::sync::Once = std::sync::Once::new();
static PROVIDER_ONCE: std::sync::Once = std::sync::Once::new();

/// reqwest in isideload is built `rustls-no-provider`: building a Client
/// panics ("No rustls crypto provider is configured") unless a provider
/// is installed process-wide first. Apparition's core does this on its
/// own init path; our FFI entry does it here. Errors (already installed)
/// are fine.
fn install_crypto_provider() {
    PROVIDER_ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

pub(crate) fn diag(stage: &str) {
    let guard = DIAG_PATH.lock().ok();
    let Some(Some(path)) = guard.as_ref().map(|g| g.as_ref()) else { return };
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{stage}");
    }
}

fn install_panic_hook() {
    HOOK_ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string payload>".to_string()
            };
            let location = info.location().map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column())).unwrap_or_else(|| "?".to_string());
            diag(&format!("PANIC: {payload} @ {location}"));
        }));
    });
}

#[no_mangle]
pub unsafe extern "C" fn apparition_set_diagnostic_log(path: *const c_char) {
    if path.is_null() {
        return;
    }
    if let Ok(text) = unsafe { CStr::from_ptr(path) }.to_str() {
        if let Ok(mut guard) = DIAG_PATH.lock() {
            *guard = Some(std::path::PathBuf::from(text));
        }
    }
}

/// An Android phone running Apple Music, for anisette made by Apple Music's Android libraries.
pub const ANDROID_CLIENT_INFO: &str = "<Pixel 8><Android; 14; UQ1A.240205.004><com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>";
/// A Mac's AuthKit daemon, claimed after sign-in for the Xcode token.
pub const MAC_CLIENT_INFO: &str = "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
pub const USER_AGENT: &str = "akd/1.0 CFNetwork/808.1.4";

const APPARITION_OK: i32 = 0;
const APPARITION_INVALID_ARGUMENT: i32 = -2;
const APPARITION_LOGIN_FAILED: i32 = 2;

fn android_info() -> AnisetteClientInfo {
    AnisetteClientInfo { client_info: ANDROID_CLIENT_INFO.to_string(), user_agent: USER_AGENT.to_string() }
}

fn mac_info() -> AnisetteClientInfo {
    AnisetteClientInfo { client_info: MAC_CLIENT_INFO.to_string(), user_agent: USER_AGENT.to_string() }
}

/// The code of the GrandSlam error behind `error` (-22411, -80045...), if one is.
/// (Same helper as Apparition's core.)
fn auth_code(error: &Report) -> Option<i64> {
    error.iter_reports().find_map(|cause| match cause.downcast_current_context::<isideload::SideloadError>()? {
        isideload::SideloadError::AuthWithMessage(code, _) => Some(*code),
        _ => None,
    })
}

/// Runs a job on the ADI engine thread; the engine must already be
/// initialized (and selected to this provider's identity) by
/// `apparition_adi_init`.
async fn engine_call<R, F>(job: F) -> std::result::Result<R, String>
where
    R: Send + 'static,
    F: FnOnce(&crate::adi::Exports) -> R + Send + 'static,
{
    tokio::task::spawn_blocking(move || with_engine(job).map_err(|code| format!("ADI engine call failed (ffi rc={code})")))
        .await
        .map_err(|e| format!("ADI engine task stopped: {e}"))?
}

/// An AnisetteProvider backed by the in-process ADI engine.
pub struct LocalAdiProvider {
    identifier_bytes: [u8; 16],
    /// Lowercase UUID string, as isideload's own state would produce.
    device_id: String,
}

impl LocalAdiProvider {
    fn md_lu_hex(&self) -> String {
        hex::encode(Sha256::digest(self.identifier_bytes))
    }

    fn provisioning_headers(&self) -> std::result::Result<HeaderMap, String> {
        let mut headers = HeaderMap::new();
        headers.insert("X-Apple-I-MD-LU", HeaderValue::from_str(&self.md_lu_hex()).map_err(|e| e.to_string())?);
        headers.insert("X-Mme-Device-Id", HeaderValue::from_str(&self.device_id).map_err(|e| e.to_string())?);
        Ok(headers)
    }
}

#[async_trait::async_trait]
impl AnisetteProvider for LocalAdiProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
        diag("stage: anisette requested (engine login_code probe)");
        let code = engine_call(|exports| exports.login_code()).await.map_err(|e| rootcause::report!("{e}"))?;
        if code != 0 {
            // -45061 is "not provisioned"; any other non-zero code gets the
            // same treatment — provision() will surface the real error if
            // the identity is broken in some other way.
            return Ok(AnisetteDataResponse::NeedsProvisioning);
        }
        let otp = engine_call(|exports| exports.request_otp()).await.map_err(|e| rootcause::report!("{e}"))?.map_err(|e| rootcause::report!("{e}"))?;
        diag("stage: engine OTP ok");
        Ok(AnisetteDataResponse::Data(AnisetteData::new(
            B64.encode(&otp.machine_id),
            B64.encode(&otp.one_time_password),
            "17106176".to_string(),
            ANDROID_CLIENT_INFO.to_string(),
            self.device_id.clone(),
            self.md_lu_hex(),
        )))
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        Ok(android_info())
    }

    async fn provision(&mut self, gs: &Arc<GrandSlam>, _force_recheck: bool) -> Result<(), Report> {
        diag("stage: provisioning start");
        // Same exchange as isideload's remote_v3 client performs against
        // Apple (its server half does the ADI calls; here they are local).
        let start_url = gs.get_url("midStartProvisioning")?;
        let end_url = gs.get_url("midFinishProvisioning")?;
        let headers = self.provisioning_headers().map_err(|e| rootcause::report!("{e}"))?;

        let body: Dictionary = plist!(dict {
            "Header": {},
            "Request": {}
        });
        let response = gs.plist_request(&start_url, &body, Some(headers.clone()), None).await.context("Failed to send start provisioning request")?;
        let spim_text = response.get("spim").and_then(|v| v.as_string()).ok_or_else(|| rootcause::report!("Start provisioning response missing spim"))?;
        let spim = B64.decode(spim_text).map_err(|e| rootcause::report!("spim isn't base64: {e}"))?;

        let (cpim, session) = engine_call(move |exports| exports.start_provisioning(&spim)).await.map_err(|e| rootcause::report!("{e}"))?.map_err(|e| rootcause::report!("{e}"))?;

        let body: Dictionary = plist!(dict {
            "Header": {},
            "Request": {
                "cpim": B64.encode(&cpim),
            }
        });
        let response = gs.plist_request(&end_url, &body, Some(headers), None).await.context("Failed to send end provisioning request")?;
        let ptm_text = response.get("ptm").and_then(|v| v.as_string()).ok_or_else(|| rootcause::report!("End provisioning response missing ptm"))?;
        let tk_text = response.get("tk").and_then(|v| v.as_string()).ok_or_else(|| rootcause::report!("End provisioning response missing tk"))?;
        let ptm = B64.decode(ptm_text).map_err(|e| rootcause::report!("ptm isn't base64: {e}"))?;
        let tk = B64.decode(tk_text).map_err(|e| rootcause::report!("tk isn't base64: {e}"))?;

        engine_call(move |exports| exports.end_provisioning(session, &ptm, &tk)).await.map_err(|e| rootcause::report!("{e}"))?.map_err(|e| rootcause::report!("{e}"))?;
        diag("stage: provisioning done");
        Ok(())
    }
}

// MARK: - 2FA bridge to Swift

/// Swift-side 2FA callback: receives the callback params as JSON, writes
/// back one action string: "code:<digits>", "sms:<number id>", "voice:<number id>", "devices",
/// "resend" or "abort". Returns 0 when an action was written.
pub type TwoFactorCallback = unsafe extern "C" fn(ctx: *mut c_void, params_json: *const c_char, out_action: *mut c_char, out_action_cap: usize) -> i32;

struct CallbackBridge {
    cb: TwoFactorCallback,
    ctx: usize, // *mut c_void, ferried across threads
}

unsafe impl Send for CallbackBridge {}
unsafe impl Sync for CallbackBridge {}

fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn params_json(params: &TwoFactorCallbackParams) -> String {
    let numbers: Vec<String> = params
        .numbers
        .iter()
        .map(|n| {
            format!(
                "{{\"id\":{},\"last_two\":\"{}\",\"number_with_dial_code\":\"{}\"}}",
                n.id,
                json_escape(&n.last_two_digits),
                json_escape(&n.number_with_dial_code)
            )
        })
        .collect();
    let last_error = params.last_error.as_ref().map(|e| format!("\"{}\"", json_escape(e))).unwrap_or_else(|| "null".to_string());
    let selected = params.selected_number_id.map(|id| id.to_string()).unwrap_or_else(|| "null".to_string());
    format!(
        "{{\"unknown\":{},\"sms\":{},\"voice\":{},\"last_error\":{},\"selected_number_id\":{},\"numbers\":[{}]}}",
        params.unknown, params.sms, params.voice, last_error, selected,
        numbers.join(",")
    )
}

fn parse_two_factor_action(action: &str) -> std::result::Result<TwoFactorCallbackResponse, String> {
    if let Some(code) = action.strip_prefix("code:") {
        Ok(TwoFactorCallbackResponse::SubmitCode(code.to_string()))
    } else if let Some(id) = action.strip_prefix("sms:") {
        id.parse::<u32>()
            .map(TwoFactorCallbackResponse::SendSms)
            .map_err(|_| format!("bad sms id in action: {action}"))
    } else if let Some(id) = action.strip_prefix("voice:") {
        id.parse::<u32>()
            .map(TwoFactorCallbackResponse::SendVoice)
            .map_err(|_| format!("bad voice id in action: {action}"))
    } else {
        match action {
            "devices" => Ok(TwoFactorCallbackResponse::SendToDevices),
            "resend" => Ok(TwoFactorCallbackResponse::ResendCode),
            _ => Ok(TwoFactorCallbackResponse::Abort),
        }
    }
}

impl CallbackBridge {
    fn ask(&self, params: TwoFactorCallbackParams) -> std::result::Result<TwoFactorCallbackResponse, String> {
        diag("stage: 2FA callback invoked");
        let json = params_json(&params);
        let c_json = std::ffi::CString::new(json).map_err(|_| "params JSON contains a NUL".to_string())?;
        let mut buf = vec![0u8; 512];
        let rc = unsafe { (self.cb)(self.ctx as *mut c_void, c_json.as_ptr(), buf.as_mut_ptr() as *mut c_char, buf.len()) };
        if rc != 0 {
            return Ok(TwoFactorCallbackResponse::Abort);
        }
        let nul = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
        let action = String::from_utf8_lossy(&buf[..nul]).into_owned();
        parse_two_factor_action(&action)
    }
}

// MARK: - Callback provider (anisette supplied by Swift)
//
// A second provider whose anisette comes from the app itself — in ODATest
// that is AnisetteKit's Unicorn-emulated client (ODARunner's engine).
// This puts every login in the app on isideload, whatever generates the
// anisette. The provider claims whatever the app tells it to claim; the
// data itself is opaque to us.

/// Swift-side anisette callback. `kind` 0 = fetch headers JSON into
/// `out_json`: {"machine_id","one_time_password","routing_info",
/// "device_id","local_user_id"} (the X-Apple-I-MD-M / -MD / -MD-RINFO /
/// X-Mme-Device-Id / X-Apple-I-MD-LU values). Returns 0 on success, 1
/// when the anisette isn't provisioned, anything else on error.
/// `kind` 1 = (re)provision, then return 0.
pub type HeadersCallback = unsafe extern "C" fn(ctx: *mut c_void, kind: i32, out_json: *mut c_char, out_json_cap: usize) -> i32;

pub struct CallbackProvider {
    cb: HeadersCallback,
    ctx: usize, // *mut c_void, ferried across threads
    claim: AnisetteClientInfo,
}

unsafe impl Send for CallbackProvider {}
unsafe impl Sync for CallbackProvider {}

impl CallbackProvider {
    fn fetch(&self, kind: i32) -> std::result::Result<String, i32> {
        let mut buf = vec![0u8; 8192];
        let rc = unsafe { (self.cb)(self.ctx as *mut c_void, kind, buf.as_mut_ptr() as *mut c_char, buf.len()) };
        if rc != 0 {
            return Err(rc);
        }
        let nul = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
        Ok(String::from_utf8_lossy(&buf[..nul]).into_owned())
    }
}

#[async_trait::async_trait]
impl AnisetteProvider for CallbackProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
        diag("stage: anisette requested (app headers callback)");
        let fetched = {
            let this = CallbackProvider { cb: self.cb, ctx: self.ctx, claim: self.claim.clone() };
            tokio::task::spawn_blocking(move || this.fetch(0)).await.map_err(|e| rootcause::report!("anisette callback task stopped: {e}"))?
        };
        let json = match fetched {
            Ok(json) => json,
            Err(1) => return Ok(AnisetteDataResponse::NeedsProvisioning),
            Err(rc) => return Err(rootcause::report!("anisette callback failed (rc={rc})")),
        };
        let value: serde_json::Value = serde_json::from_str(&json).map_err(|e| rootcause::report!("anisette callback returned bad JSON: {e}"))?;
        let field = |name: &str| -> Result<String, Report> {
            // Accept JSON strings, and also bare numbers (routing_info is
            // numeric in spirit; a sender encoding it as a JSON number is
            // not "missing" it).
            let parsed = value.get(name).and_then(|v| {
                v.as_str().map(|s| s.to_string())
                    .or_else(|| v.as_u64().map(|n| n.to_string()))
                    .or_else(|| v.as_i64().map(|n| n.to_string()))
            });
            parsed.ok_or_else(|| rootcause::report!("anisette JSON missing {name}"))
        };
        Ok(AnisetteDataResponse::Data(AnisetteData::new(
            field("machine_id")?,
            field("one_time_password")?,
            field("routing_info")?,
            self.claim.client_info.clone(),
            field("device_id")?,
            field("local_user_id")?,
        )))
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        Ok(self.claim.clone())
    }

    async fn provision(&mut self, _gs: &Arc<GrandSlam>, _force_recheck: bool) -> Result<(), Report> {
        let this = CallbackProvider { cb: self.cb, ctx: self.ctx, claim: self.claim.clone() };
        let done = tokio::task::spawn_blocking(move || this.fetch(1)).await.map_err(|e| rootcause::report!("anisette callback task stopped: {e}"))?;
        match done {
            Ok(_) => Ok(()),
            Err(rc) => Err(rootcause::report!("anisette (re)provisioning failed (rc={rc})")),
        }
    }
}

// MARK: - The sign-in flow

async fn sign_in<P>(email: &str, password: &str, provider: P, bridge: Arc<CallbackBridge>) -> Result<String, Report>
where
    P: AnisetteProvider + Send + Sync + 'static,
{
    let callback = move |params: TwoFactorCallbackParams| {
        let bridge = bridge.clone();
        async move {
            let ask = tokio::task::spawn_blocking(move || bridge.ask(params)).await.map_err(|e| rootcause::report!("2FA bridge task stopped: {e}"))?;
            ask.map_err(|e| rootcause::report!("{e}"))
        }
    };

    diag("stage: account build (URL bag) + SRP login");
    let mut account = AppleAccount::builder(email)
        .anisette_provider(provider)
        .login(password, callback.clone())
        .await
        .context("Apple ID sign-in failed")?;
    diag("stage: SRP login ok");

    // after_sign_in: the Xcode token (and developer requests made with it)
    // are claimed as a Mac when the sign-in claimed Android.
    let signing_in = account.grandslam_client.clone();
    account.grandslam_client = Arc::new(signing_in.claiming(mac_info()));

    let mut session = match DeveloperSession::from_account(&mut account).await {
        Ok(session) => {
            diag("stage: developer session ok (Xcode token)");
            session
        }
        Err(error) if auth_code(&error) == Some(-22411) => {
            diag("stage: -22411, second login with code_after_login");
            // An Android-claimed sign-in Apple doesn't trust yet: sign in
            // again with code_after_login so the pushed code gets checked,
            // then claim Mac again for the token.
            account.grandslam_client = signing_in.clone();
            account.code_after_login = true;
            account.login(password, callback).await.context("Second sign-in (code_after_login) failed")?;
            account.grandslam_client = Arc::new(signing_in.claiming(mac_info()));
            DeveloperSession::from_account(&mut account).await.context("Failed to open a developer session")?
        }
        Err(error) => return Err(error.context("Failed to open a developer session").into_dynamic()),
    };

    let teams = session.list_teams().await.context("Failed to list developer teams")?;
    diag("stage: teams listed");

    // EiliStore port: the success payload is structured JSON so the host
    // can build its stored SideSign AuthSession (account + PET session)
    // from the sign-in — first/last name from the account SPD, adsid and
    // the Xcode app token from the DeveloperSession.
    let (first_name, last_name) = account.get_name().unwrap_or_default();
    let payload = serde_json::json!({
        "first_name": first_name,
        "last_name": last_name,
        "adsid": session.adsid(),
        "token": session.app_token().token.clone(),
        "token_duration": session.app_token().duration,
        "teams": teams
            .iter()
            .map(|t| serde_json::json!({
                "name": t.name.clone().unwrap_or_default(),
                "id": t.team_id.clone(),
            }))
            .collect::<Vec<_>>(),
    });
    Ok(payload.to_string())
}

// MARK: - FFI

unsafe fn read_str(ptr: *const c_char, what: &str) -> std::result::Result<String, i32> {
    if ptr.is_null() {
        return Err(fail(APPARITION_INVALID_ARGUMENT, &format!("null {what}")));
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().map(|s| s.to_string()).map_err(|_| fail(APPARITION_INVALID_ARGUMENT, &format!("{what} isn't UTF-8")))
}

fn parse_uuid_bytes(text: &str) -> Option<[u8; 16]> {
    let hex: String = text.chars().filter(|c| *c != '-').collect();
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for i in 0..16 {
        bytes[i] = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(bytes)
}

fn finish<P>(
    email: &str,
    password: &str,
    provider: P,
    bridge: Arc<CallbackBridge>,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32
where
    P: AnisetteProvider + Send + Sync + 'static,
{
    install_panic_hook();
    install_crypto_provider();
    diag("stage: login entry");
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            unsafe { write_error(err_buf, err_len, &format!("failed to build the tokio runtime: {e}")) };
            return APPARITION_LOGIN_FAILED;
        }
    };
    diag("stage: tokio runtime built");
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| runtime.block_on(sign_in(email, password, provider, bridge))));
    match outcome {
        Ok(Ok(summary)) => {
            unsafe { write_error(out_summary, out_summary_cap, &summary) };
            APPARITION_OK
        }
        Ok(Err(error)) => {
            let detail = match auth_code(&error) {
                Some(code) => format!("auth_code={code} — {error:?}"),
                None => format!("{error:?}"),
            };
            unsafe { write_error(err_buf, err_len, &detail) };
            APPARITION_LOGIN_FAILED
        }
        Err(payload) => {
            let message = if let Some(s) = payload.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            diag(&format!("stage: panic caught at FFI boundary: {message}"));
            unsafe { write_error(err_buf, err_len, &format!("Rust panic（已攔截）: {message}")) };
            APPARITION_LOGIN_FAILED
        }
    }
}

/// Signs in with isideload (Apparition's vendored copy) using the local
/// ADI engine's anisette. The engine must already be initialized with
/// `apparition_adi_init` for the same identifier + data_dir.
///
/// On success returns 0 and writes a NUL-terminated summary (account +
/// teams) into `out_summary`. On failure returns 2 and writes the error
/// (prefixed with the GrandSlam auth code when there is one) into
/// `err_buf`. Invalid arguments return -2.
#[no_mangle]
pub unsafe extern "C" fn apparition_login(
    email: *const c_char,
    password: *const c_char,
    identifier_uuid: *const c_char,
    data_dir: *const c_char,
    two_factor_cb: TwoFactorCallback,
    two_factor_ctx: *mut c_void,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32 {
    let parsed = (|| -> std::result::Result<(String, String, LocalAdiProvider), i32> {
        let email = unsafe { read_str(email, "email") }?;
        let password = unsafe { read_str(password, "password") }?;
        let identifier_uuid = unsafe { read_str(identifier_uuid, "identifier_uuid") }?;
        let _data_dir = unsafe { read_str(data_dir, "data_dir") }?;
        let identifier_bytes = parse_uuid_bytes(&identifier_uuid)
            .ok_or_else(|| fail(APPARITION_INVALID_ARGUMENT, "identifier_uuid isn't a UUID"))?;
        let provider = LocalAdiProvider { identifier_bytes, device_id: identifier_uuid.to_lowercase() };
        Ok((email, password, provider))
    })();
    let (email, password, provider) = match parsed {
        Ok(values) => values,
        Err(code) => {
            let message = crate::LAST_ERROR.lock().map(|slot| slot.clone()).unwrap_or_default();
            unsafe { write_error(err_buf, err_len, &message) };
            return code;
        }
    };
    let bridge = Arc::new(CallbackBridge { cb: two_factor_cb, ctx: two_factor_ctx as usize });
    finish(&email, &password, provider, bridge, out_summary, out_summary_cap, err_buf, err_len)
}

/// Signs in with isideload using anisette supplied by the app through
/// `headers_cb` (see `CallbackProvider`), claiming `claim_client_info`.
/// Same return contract as `apparition_login`.
#[no_mangle]
pub unsafe extern "C" fn apparition_login_with_headers(
    email: *const c_char,
    password: *const c_char,
    claim_client_info: *const c_char,
    headers_cb: HeadersCallback,
    headers_ctx: *mut c_void,
    two_factor_cb: TwoFactorCallback,
    two_factor_ctx: *mut c_void,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32 {
    let parsed = (|| -> std::result::Result<(String, String, CallbackProvider), i32> {
        let email = unsafe { read_str(email, "email") }?;
        let password = unsafe { read_str(password, "password") }?;
        let claim = unsafe { read_str(claim_client_info, "claim_client_info") }?;
        let provider = CallbackProvider {
            cb: headers_cb,
            ctx: headers_ctx as usize,
            claim: AnisetteClientInfo { client_info: claim, user_agent: USER_AGENT.to_string() },
        };
        Ok((email, password, provider))
    })();
    let (email, password, provider) = match parsed {
        Ok(values) => values,
        Err(code) => {
            let message = crate::LAST_ERROR.lock().map(|slot| slot.clone()).unwrap_or_default();
            unsafe { write_error(err_buf, err_len, &message) };
            return code;
        }
    };
    let bridge = Arc::new(CallbackBridge { cb: two_factor_cb, ctx: two_factor_ctx as usize });
    finish(&email, &password, provider, bridge, out_summary, out_summary_cap, err_buf, err_len)
}

// MARK: - Developer operations on a stored session (path B)
//
// The host app stores the Xcode app token + adsid from a completed
// sign-in. These entry points rebuild a DeveloperSession from those two
// values — GrandSlam client claiming the same Mac identity the token
// was minted under, anisette supplied by the app through the same
// callback as login — so developer requests keep the exact shape
// isideload itself uses (the token is never presented through another
// stack's request shape).

async fn dev_list_teams(token: String, adsid: String, provider: CallbackProvider) -> Result<String, Report> {
    let client = GrandSlam::new(mac_info(), false, None).await.context("Failed to build the developer client")?;
    let generator = AnisetteDataGenerator::new(Arc::new(RwLock::new(provider)));
    let app_token = AppToken { token, duration: 0, expiry: 0 };
    let mut session = DeveloperSession::new(app_token, adsid, Arc::new(client), generator);
    let teams = session.list_teams().await.context("Failed to list developer teams")?;
    let payload = serde_json::json!({
        "teams": teams
            .iter()
            .map(|t| serde_json::json!({
                "name": t.name.clone().unwrap_or_default(),
                "id": t.team_id.clone(),
                "type": t.r#type.clone().unwrap_or_default(),
            }))
            .collect::<Vec<_>>(),
    });
    Ok(payload.to_string())
}

fn finish_dev(
    future: impl std::future::Future<Output = Result<String, Report>>,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32 {
    install_panic_hook();
    install_crypto_provider();
    diag("stage: dev op entry");
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            unsafe { write_error(err_buf, err_len, &format!("failed to build the tokio runtime: {e}")) };
            return APPARITION_LOGIN_FAILED;
        }
    };
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| runtime.block_on(future)));
    match outcome {
        Ok(Ok(summary)) => {
            unsafe { write_error(out_summary, out_summary_cap, &summary) };
            APPARITION_OK
        }
        Ok(Err(error)) => {
            unsafe { write_error(err_buf, err_len, &format!("{error:?}")) };
            APPARITION_LOGIN_FAILED
        }
        Err(payload) => {
            let message = if let Some(s) = payload.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            diag(&format!("stage: panic caught at FFI boundary: {message}"));
            unsafe { write_error(err_buf, err_len, &format!("Rust panic（已攔截）: {message}")) };
            APPARITION_LOGIN_FAILED
        }
    }
}

/// Lists the stored session's developer teams through isideload's own
/// request shape, rebuilding the DeveloperSession from the stored Xcode
/// app token + adsid. Anisette comes from the app via `headers_cb`
/// (same callback contract as `apparition_login_with_headers`); the
/// claim is the Android label the sign-in used (the developer client
/// itself claims the Mac identity, as after a sign-in). Returns 0 with
/// a JSON summary {"teams":[{name,id,type}]} in `out_summary`, 2 with
/// the error in `err_buf`, -2 on invalid arguments.
#[no_mangle]
pub unsafe extern "C" fn apparition_dev_list_teams(
    token: *const c_char,
    adsid: *const c_char,
    claim_client_info: *const c_char,
    headers_cb: HeadersCallback,
    headers_ctx: *mut c_void,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32 {
    let parsed = (|| -> std::result::Result<(String, String, CallbackProvider), i32> {
        let token = unsafe { read_str(token, "token") }?;
        let adsid = unsafe { read_str(adsid, "adsid") }?;
        let claim = unsafe { read_str(claim_client_info, "claim_client_info") }?;
        let provider = CallbackProvider {
            cb: headers_cb,
            ctx: headers_ctx as usize,
            claim: AnisetteClientInfo { client_info: claim, user_agent: USER_AGENT.to_string() },
        };
        Ok((token, adsid, provider))
    })();
    let (token, adsid, provider) = match parsed {
        Ok(values) => values,
        Err(code) => {
            let message = crate::LAST_ERROR.lock().map(|slot| slot.clone()).unwrap_or_default();
            unsafe { write_error(err_buf, err_len, &message) };
            return code;
        }
    };
    finish_dev(dev_list_teams(token, adsid, provider), out_summary, out_summary_cap, err_buf, err_len)
}

// MARK: - Developer operations dispatcher (path B, phase 2)
//
// One generic entry point for the portal operations the signing /
// refresh pipeline needs. Each call rebuilds the DeveloperSession from
// the stored token + adsid exactly like `apparition_dev_list_teams`,
// runs one isideload dev-API operation, and returns a small JSON
// document for the host to map onto its own model types.

fn app_id_json(app_id: &AppId) -> serde_json::Value {
    let mut features = serde_json::Map::new();
    for (key, value) in app_id.features.iter() {
        let mapped = match value {
            plist::Value::String(text) => serde_json::json!(text),
            plist::Value::Boolean(flag) => serde_json::json!(if *flag { "true" } else { "false" }),
            plist::Value::Integer(number) => serde_json::json!(number.to_string()),
            _ => serde_json::json!(format!("{value:?}")),
        };
        features.insert(key.clone(), mapped);
    }
    serde_json::json!({
        "app_id_id": app_id.app_id_id,
        "identifier": app_id.identifier,
        "name": app_id.name,
        "features": features,
    })
}

fn app_group_json(group: &AppGroup) -> serde_json::Value {
    serde_json::json!({
        "application_group": group.application_group,
        "identifier": group.identifier,
        "name": group.name.clone().unwrap_or_default(),
    })
}

fn device_json(device: &isideload::dev::devices::DeveloperDevice) -> serde_json::Value {
    serde_json::json!({
        "device_id": device.device_id.clone().unwrap_or_default(),
        "device_number": device.device_number,
        "name": device.name.clone().unwrap_or_default(),
        "status": device.status.clone().unwrap_or_default(),
    })
}


#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedProfile {
    provisioning_profile_id: Option<String>,
    name: String,
    status: Option<String>,
    #[serde(rename = "type")]
    profile_type: Option<String>,
    #[serde(rename = "UUID")]
    uuid: String,
    date_expire: plist::Date,
    app_id: Option<ListedProfileApp>,
    device_ids: Option<Vec<String>>,
    is_team_profile: Option<bool>,
    is_free_provisioning_profile: Option<bool>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedProfileApp {
    app_id_id: Option<String>,
    identifier: Option<String>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DownloadedProfile {
    encoded_profile: plist::Data,
    provisioning_profile_id: Option<String>,
    name: Option<String>,
    #[serde(rename = "UUID")]
    uuid: Option<String>,
}

fn downloaded_profile_json(profile: &DownloadedProfile) -> serde_json::Value {
    serde_json::json!({
        "profile_b64": B64.encode(profile.encoded_profile.as_ref()),
        "provisioning_profile_id": profile.provisioning_profile_id.clone().unwrap_or_default(),
        "uuid": profile.uuid.clone().unwrap_or_default(),
        "name": profile.name.clone().unwrap_or_default(),
    })
}

fn param_str_array(params: &serde_json::Value, key: &str) -> Vec<plist::Value> {
    params
        .get(key)
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|text| plist::Value::String(text.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

fn param_str<'a>(params: &'a serde_json::Value, key: &str) -> String {
    params.get(key).and_then(|v| v.as_str()).unwrap_or_default().to_string()
}

async fn dev_op(op: String, params: serde_json::Value, token: String, adsid: String, provider: CallbackProvider) -> Result<String, Report> {
    let client = GrandSlam::new(mac_info(), false, None).await.context("Failed to build the developer client")?;
    let generator = AnisetteDataGenerator::new(Arc::new(RwLock::new(provider)));
    let app_token = AppToken { token, duration: 0, expiry: 0 };
    let mut session = DeveloperSession::new(app_token, adsid, Arc::new(client), generator);
    let team = DeveloperTeam {
        name: None,
        team_id: param_str(&params, "team_id"),
        r#type: None,
        status: None,
    };
    let ios = DeveloperDeviceType::Ios;

    let payload: serde_json::Value = match op.as_str() {
        "list_certs" => {
            let certs = session.list_ios_certs(&team).await.context("Failed to list certificates")?;
            serde_json::json!({
                "certs": certs.iter().map(|c| serde_json::json!({
                    "certificate_id": c.certificate_id.clone().unwrap_or_default(),
                    "serial_number": c.serial_number.clone().unwrap_or_default(),
                    "machine_name": c.machine_name.clone().unwrap_or_default(),
                    "machine_id": c.machine_id.clone().unwrap_or_default(),
                    "status": c.status.clone().unwrap_or_default(),
                    "cert_content_b64": c.cert_content.as_ref().map(|d| B64.encode(d.as_ref())).unwrap_or_default(),
                })).collect::<Vec<_>>(),
            })
        }
        "submit_csr" => {
            let request = session
                .submit_development_csr(&team, param_str(&params, "csr_content"), param_str(&params, "machine_name"), ios)
                .await
                .context("Failed to submit development CSR")?;
            serde_json::json!({ "cert_request_id": request.cert_request_id })
        }
        "revoke_cert" => {
            session
                .revoke_development_cert(&team, &param_str(&params, "serial_number"), ios)
                .await
                .context("Failed to revoke certificate")?;
            serde_json::json!({})
        }
        "list_devices" => {
            let devices = session.list_devices(&team, ios).await.context("Failed to list devices")?;
            serde_json::json!({ "devices": devices.iter().map(device_json).collect::<Vec<_>>() })
        }
        "add_device" => {
            let device = session
                .add_device(&team, &param_str(&params, "name"), &param_str(&params, "device_number"), ios)
                .await
                .context("Failed to add device")?;
            serde_json::json!({ "device": device_json(&device) })
        }
        "list_app_ids" => {
            let response = session.list_app_ids(&team, ios).await.context("Failed to list app IDs")?;
            serde_json::json!({ "app_ids": response.app_ids.iter().map(app_id_json).collect::<Vec<_>>() })
        }
        "add_app_id" => {
            let name = param_str(&params, "name");
            let identifier = param_str(&params, "identifier");
            // 診斷（2026-10-28 真機）：Apple 回 35「No value was provided for
            // the parameter 'appIdentifierString'」——同形請求在 SideSign 路徑
            // 可成功，剩餘嫌疑是送進來的值本身為空。空值直接在本地擋下並
            // 講清收到什麼；非空但被 Apple 拒時，錯誤鏈帶出實際送出的值，
            // 一次截圖就能定案，不再隔空猜參數名。
            if name.is_empty() || identifier.is_empty() {
                return Err(rootcause::report!(
                    "add_app_id 未送出：參數為空（name={name:?}, identifier={identifier:?}）"
                ));
            }
            let app_id = session
                .add_app_id(&team, &name, &identifier, ios)
                .await
                .context(format!("Failed to add app ID (name={name:?}, identifier={identifier:?})"))?;
            serde_json::json!({ "app_id": app_id_json(&app_id) })
        }
        "update_app_id" => {
            let app_id = AppId {
                app_id_id: param_str(&params, "app_id_id"),
                identifier: param_str(&params, "identifier"),
                name: param_str(&params, "name"),
                features: plist::Dictionary::new(),
                expiration_date: None,
            };
            let mut features = plist::Dictionary::new();
            if let Some(map) = params.get("features").and_then(|v| v.as_object()) {
                for (key, value) in map {
                    if let Some(text) = value.as_str() {
                        features.insert(key.clone(), plist::Value::String(text.to_string()));
                    }
                }
            }
            let updated = session.update_app_id(&team, &app_id, features, ios).await.context("Failed to update app ID")?;
            serde_json::json!({ "app_id": app_id_json(&updated) })
        }
        "delete_app_id" => {
            session.delete_app_id(&team, &param_str(&params, "app_id_id"), ios).await.context("Failed to delete app ID")?;
            serde_json::json!({})
        }
        "list_app_groups" => {
            let groups = session.list_app_groups(&team, ios).await.context("Failed to list app groups")?;
            serde_json::json!({ "groups": groups.iter().map(app_group_json).collect::<Vec<_>>() })
        }
        "add_app_group" => {
            let group = session
                .add_app_group(&team, &param_str(&params, "name"), &param_str(&params, "identifier"), ios)
                .await
                .context("Failed to add app group")?;
            serde_json::json!({ "group": app_group_json(&group) })
        }
        "assign_app_group" => {
            let group = AppGroup {
                name: Some(param_str(&params, "group_name")),
                identifier: param_str(&params, "group_identifier"),
                application_group: param_str(&params, "application_group"),
            };
            let app_id = AppId {
                app_id_id: param_str(&params, "app_id_id"),
                identifier: String::new(),
                name: String::new(),
                features: plist::Dictionary::new(),
                expiration_date: None,
            };
            session.assign_app_group(&team, &group, &app_id, ios).await.context("Failed to assign app group")?;
            serde_json::json!({})
        }
        "download_team_profile" => {
            let app_id = AppId {
                app_id_id: param_str(&params, "app_id_id"),
                identifier: param_str(&params, "identifier"),
                name: param_str(&params, "name"),
                features: plist::Dictionary::new(),
                expiration_date: None,
            };
            let profile = session
                .download_team_provisioning_profile(&team, &app_id, ios)
                .await
                .context("Failed to download team provisioning profile")?;
            serde_json::json!({
                "profile_b64": B64.encode(profile.encoded_profile.as_ref()),
                "provisioning_profile_id": profile.provisioning_profile_id,
                "uuid": profile.uuid,
                "name": profile.name,
            })
        }
        "list_profiles" => {
            let body = plist_macro::plist!(dict {
                "teamId": team.team_id.clone(),
                "includeTeamProfiles": true,
            });
            let profiles: Vec<ListedProfile> = session
                .send_dev_request(&dev_url("listProvisioningProfiles", ios), body, "provisioningProfiles")
                .await
                .context("Failed to list provisioning profiles")?;
            serde_json::json!({
                "profiles": profiles.iter().map(|profile| serde_json::json!({
                    "provisioning_profile_id": profile.provisioning_profile_id.clone().unwrap_or_default(),
                    "name": profile.name,
                    "status": profile.status.clone().unwrap_or_default(),
                    "type": profile.profile_type.clone().unwrap_or_default(),
                    "uuid": profile.uuid,
                    "date_expire_iso": profile.date_expire.to_xml_format(),
                    "app_id_id": profile.app_id.as_ref().and_then(|a| a.app_id_id.clone()).unwrap_or_default(),
                    "bundle_id": profile.app_id.as_ref().and_then(|a| a.identifier.clone()).unwrap_or_default(),
                    "device_ids": profile.device_ids.clone().unwrap_or_default(),
                    "is_team_profile": profile.is_team_profile.unwrap_or(false),
                    "is_free": profile.is_free_provisioning_profile.unwrap_or(false),
                })).collect::<Vec<_>>(),
            })
        }
        "create_profile" | "update_profile" => {
            let is_update = op == "update_profile";
            let mut body = plist::Dictionary::new();
            body.insert("teamId".into(), plist::Value::String(team.team_id.clone()));
            if is_update {
                body.insert("provisioningProfileId".into(), plist::Value::String(param_str(&params, "provisioning_profile_id")));
            }
            body.insert("provisioningProfileName".into(), plist::Value::String(param_str(&params, "name")));
            body.insert("appIdId".into(), plist::Value::String(param_str(&params, "app_id_id")));
            body.insert("distributionType".into(), plist::Value::String("limited".into()));
            body.insert("certificateIds".into(), plist::Value::Array(param_str_array(&params, "certificate_ids")));
            body.insert("deviceIds".into(), plist::Value::Array(param_str_array(&params, "device_ids")));
            let endpoint = if is_update { "updateProvisioningProfile" } else { "createProvisioningProfile" };
            let profile: DownloadedProfile = session
                .send_dev_request(&dev_url(endpoint, ios), body, "provisioningProfile")
                .await
                .context("Failed to create provisioning profile")?;
            downloaded_profile_json(&profile)
        }
        "download_profile" => {
            let body = plist_macro::plist!(dict {
                "teamId": team.team_id.clone(),
                "provisioningProfileId": param_str(&params, "provisioning_profile_id"),
            });
            let profile: DownloadedProfile = session
                .send_dev_request(&dev_url("downloadProvisioningProfile", ios), body, "provisioningProfile")
                .await
                .context("Failed to download provisioning profile")?;
            downloaded_profile_json(&profile)
        }
        "delete_profile" => {
            let body = plist_macro::plist!(dict {
                "teamId": team.team_id.clone(),
                "provisioningProfileId": param_str(&params, "provisioning_profile_id"),
            });
            session
                .send_dev_request_no_response(&dev_url("deleteProvisioningProfile", ios), Some(body))
                .await
                .context("Failed to delete provisioning profile")?;
            serde_json::json!({})
        }
        "update_device" => {
            let mut body = plist::Dictionary::new();
            body.insert("teamId".into(), plist::Value::String(team.team_id.clone()));
            body.insert("name".into(), plist::Value::String(param_str(&params, "name")));
            body.insert("deviceNumber".into(), plist::Value::String(param_str(&params, "device_number")));
            let device_id = param_str(&params, "device_id");
            if !device_id.is_empty() {
                body.insert("deviceId".into(), plist::Value::String(device_id));
            }
            let status = param_str(&params, "status");
            if !status.is_empty() {
                body.insert("status".into(), plist::Value::String(status));
            }
            let device: isideload::dev::devices::DeveloperDevice = session
                .send_dev_request(&dev_url("updateDevice", ios), body, "device")
                .await
                .context("Failed to update device")?;
            serde_json::json!({ "device": device_json(&device) })
        }
        "disable_device" => {
            let mut body = plist::Dictionary::new();
            body.insert("teamId".into(), plist::Value::String(team.team_id.clone()));
            body.insert("deviceNumber".into(), plist::Value::String(param_str(&params, "device_number")));
            body.insert("status".into(), plist::Value::String("d".into()));
            let device_id = param_str(&params, "device_id");
            if !device_id.is_empty() {
                body.insert("deviceId".into(), plist::Value::String(device_id));
            }
            let name = param_str(&params, "name");
            if !name.is_empty() {
                body.insert("name".into(), plist::Value::String(name));
            }
            session
                .send_dev_request_no_response(&dev_url("disableDevice", ios), Some(body))
                .await
                .context("Failed to disable device")?;
            serde_json::json!({})
        }
        "delete_device" => {
            let mut body = plist::Dictionary::new();
            body.insert("teamId".into(), plist::Value::String(team.team_id.clone()));
            body.insert("deviceNumber".into(), plist::Value::String(param_str(&params, "device_number")));
            let device_id = param_str(&params, "device_id");
            if !device_id.is_empty() {
                body.insert("deviceId".into(), plist::Value::String(device_id));
            }
            session
                .send_dev_request_no_response(&dev_url("deleteDevice", ios), Some(body))
                .await
                .context("Failed to delete device")?;
            serde_json::json!({})
        }
        "update_app_group" => {
            let body = plist_macro::plist!(dict {
                "teamId": team.team_id.clone(),
                "name": param_str(&params, "name"),
                "applicationGroup": param_str(&params, "application_group"),
                "identifier": param_str(&params, "group_identifier"),
            });
            let group: AppGroup = session
                .send_dev_request(&dev_url("updateApplicationGroup", ios), body, "applicationGroup")
                .await
                .context("Failed to update app group")?;
            serde_json::json!({ "group": app_group_json(&group) })
        }
        "delete_app_group" => {
            let body = plist_macro::plist!(dict {
                "teamId": team.team_id.clone(),
                "applicationGroup": param_str(&params, "application_group"),
            });
            session
                .send_dev_request_no_response(&dev_url("deleteApplicationGroup", ios), Some(body))
                .await
                .context("Failed to delete app group")?;
            serde_json::json!({})
        }
        other => {
            return Err(rootcause::report!("unknown dev op: {other}"));
        }
    };
    Ok(payload.to_string())
}

/// Runs one developer-portal operation (see `dev_op`) against the
/// stored session. `op` names the operation, `params_json` carries its
/// arguments (always including "team_id"). Same return contract as
/// `apparition_dev_list_teams`.
#[no_mangle]
pub unsafe extern "C" fn apparition_dev_op(
    op: *const c_char,
    params_json: *const c_char,
    token: *const c_char,
    adsid: *const c_char,
    claim_client_info: *const c_char,
    headers_cb: HeadersCallback,
    headers_ctx: *mut c_void,
    out_summary: *mut c_char,
    out_summary_cap: usize,
    err_buf: *mut c_char,
    err_len: usize,
) -> i32 {
    let parsed = (|| -> std::result::Result<(String, serde_json::Value, String, String, CallbackProvider), i32> {
        let op = unsafe { read_str(op, "op") }?;
        let params_text = unsafe { read_str(params_json, "params_json") }?;
        let params: serde_json::Value = serde_json::from_str(&params_text)
            .map_err(|_| fail(APPARITION_INVALID_ARGUMENT, "params_json isn't valid JSON"))?;
        let token = unsafe { read_str(token, "token") }?;
        let adsid = unsafe { read_str(adsid, "adsid") }?;
        let claim = unsafe { read_str(claim_client_info, "claim_client_info") }?;
        let provider = CallbackProvider {
            cb: headers_cb,
            ctx: headers_ctx as usize,
            claim: AnisetteClientInfo { client_info: claim, user_agent: USER_AGENT.to_string() },
        };
        Ok((op, params, token, adsid, provider))
    })();
    let (op, params, token, adsid, provider) = match parsed {
        Ok(values) => values,
        Err(code) => {
            let message = crate::LAST_ERROR.lock().map(|slot| slot.clone()).unwrap_or_default();
            unsafe { write_error(err_buf, err_len, &message) };
            return code;
        }
    };
    finish_dev(dev_op(op, params, token, adsid, provider), out_summary, out_summary_cap, err_buf, err_len)
}


#[cfg(test)]
mod two_factor_callback_tests {
    use super::*;

    #[test]
    fn callback_actions_preserve_the_selected_delivery_method() {
        assert!(matches!(parse_two_factor_action("sms:7"), Ok(TwoFactorCallbackResponse::SendSms(7))));
        assert!(matches!(parse_two_factor_action("voice:7"), Ok(TwoFactorCallbackResponse::SendVoice(7))));
        assert!(matches!(parse_two_factor_action("code:123456"), Ok(TwoFactorCallbackResponse::SubmitCode(code)) if code == "123456"));
        assert!(parse_two_factor_action("voice:not-a-number").is_err());
    }

    #[test]
    fn callback_params_include_the_voice_mode_flag() {
        let params = TwoFactorCallbackParams {
            last_error: None,
            unknown: false,
            sms: false,
            voice: true,
            numbers: Vec::new(),
            selected_number_id: Some(7),
        };
        let json: serde_json::Value = serde_json::from_str(&params_json(&params)).unwrap();
        assert_eq!(json["sms"], false);
        assert_eq!(json["voice"], true);
        assert_eq!(json["selected_number_id"], 7);
    }
}
