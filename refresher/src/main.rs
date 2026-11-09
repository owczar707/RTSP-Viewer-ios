//! iphone-refresher – keeps a sideloaded app alive on an iPhone signed with a free Apple ID.
//!
//! Commands:
//!   check    – connects to the iPhone over Wi-Fi (no Apple login) and prints its name/UDID
//!   setup    – asks for Apple ID, password, iPhone IP and IPA path, saves them, then installs
//!   install  – signs and installs the IPA using the saved settings
//!   auto     – what the systemd timer runs: refreshes only when the last successful install
//!              is older than REFRESH_AFTER, never asks questions
//!   status   – shows when the app was last refreshed
//!
//! Everything lives in ~/.config/iphone-refresher (mode 700):
//!   config.json    – settings incl. the Apple ID password (mode 600)
//!   pairing.plist  – the iPhone's pairing record copied from the PC it trusts
//!   state/         – anisette identity and signing certificate, so Apple sees the same
//!                    "device" every time and doesn't ask for 2FA again

use std::{
    fs,
    io::{self, IsTerminal, Write},
    net::IpAddr,
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    process::ExitCode,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use idevice::{pairing_file::PairingFile, provider::TcpProvider};
use isideload::{
    anisette::{AnisetteClientInfo, remote_v3::RemoteV3AnisetteProvider},
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession},
    sideload::{
        SideloaderBuilder, TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox, MaxCertsCallbackFuture},
        device::IdeviceInfo,
        fs_storage::FsStorage,
    },
};
use rootcause::prelude::*;
use serde::{Deserialize, Serialize};

const DEFAULT_ANISETTE_URL: &str = "https://mac-ani.jkcoxson.com";
// Same identity iloader 2.4.1 presents while the anisette servers catch up with Apple's change.
const DEFAULT_CLIENT_INFO: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
const DEFAULT_USER_AGENT: &str = "akd/1.0 CFNetwork/811.5.4";

/// Free-account signatures last 7 days; refreshing after 4 leaves 3 days of retries
/// for when the iPhone is away or asleep.
const REFRESH_AFTER: Duration = Duration::from_secs(4 * 24 * 60 * 60);
/// An unattended run that hangs (e.g. the iPhone drops off Wi-Fi mid-transfer) is abandoned.
const AUTO_TIMEOUT: Duration = Duration::from_secs(15 * 60);

#[derive(Serialize, Deserialize)]
struct Config {
    apple_id: String,
    password: String,
    device_ip: String,
    ipa_path: String,
    #[serde(default = "default_anisette_url")]
    anisette_url: String,
    #[serde(default = "default_client_info")]
    client_info: String,
    #[serde(default = "default_user_agent")]
    user_agent: String,
}

fn default_anisette_url() -> String {
    DEFAULT_ANISETTE_URL.to_string()
}
fn default_client_info() -> String {
    DEFAULT_CLIENT_INFO.to_string()
}
fn default_user_agent() -> String {
    DEFAULT_USER_AGENT.to_string()
}

fn base_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".config").join("iphone-refresher")
}

fn config_path() -> PathBuf {
    base_dir().join("config.json")
}

fn pairing_path() -> PathBuf {
    base_dir().join("pairing.plist")
}

fn state_dir(name: &str) -> PathBuf {
    base_dir().join("state").join(name)
}

fn last_success_path() -> PathBuf {
    base_dir().join("state").join("last_success")
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Seconds since the last successful install, if there was one.
fn seconds_since_last_success() -> Option<u64> {
    let text = fs::read_to_string(last_success_path()).ok()?;
    let then: u64 = text.trim().parse().ok()?;
    Some(now_secs().saturating_sub(then))
}

fn record_success() {
    let path = last_success_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok();
    }
    if let Err(e) = fs::write(&path, now_secs().to_string()) {
        eprintln!("Nie można zapisać czasu odświeżenia: {e}");
    }
}

fn describe_age(seconds: u64) -> String {
    let hours = seconds / 3600;
    format!("{} dni {} godz. temu", hours / 24, hours % 24)
}

fn load_config() -> Result<Config, Report> {
    let path = config_path();
    let text = fs::read_to_string(&path)
        .context(format!("Brak konfiguracji {} – uruchom najpierw `iphone-refresher setup`", path.display()))?;
    let config = serde_json::from_str(&text).context("Nieprawidłowy plik config.json")?;
    Ok(config)
}

fn save_config(config: &Config) -> Result<(), Report> {
    fs::create_dir_all(base_dir()).context("Nie można utworzyć katalogu konfiguracji")?;
    let json = serde_json::to_string_pretty(config).context("Błąd zapisu konfiguracji")?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(config_path())
        .context("Nie można zapisać config.json")?;
    file.write_all(json.as_bytes()).context("Nie można zapisać config.json")?;
    Ok(())
}

fn device_provider(device_ip: &str) -> Result<TcpProvider, Report> {
    let addr: IpAddr = device_ip
        .trim()
        .parse()
        .context(format!("Nieprawidłowy adres IP iPhone'a: {device_ip}"))?;
    let bytes = fs::read(pairing_path()).context(format!(
        "Brak pliku parowania {} (skopiuj go z komputera, któremu ufa iPhone)",
        pairing_path().display()
    ))?;
    let pairing_file = PairingFile::from_bytes(&bytes)
        .map_err(|e| report!("Nie można odczytać pliku parowania: {e:?}"))?;
    Ok(TcpProvider {
        addr,
        scope_id: None,
        pairing_file,
        label: "iphone-refresher".to_string(),
    })
}

fn prompt(label: &str, default: Option<&str>) -> String {
    match default {
        Some(d) => print!("{label} [{d}]: "),
        None => print!("{label}: "),
    }
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().read_line(&mut line).ok();
    let value = line.trim().to_string();
    match (value.is_empty(), default) {
        (true, Some(d)) => d.to_string(),
        _ => value,
    }
}

async fn check(device_ip: &str) -> Result<(), Report> {
    let provider = device_provider(device_ip)?;
    let info = IdeviceInfo::from_device(&provider).await?;
    println!("Połączono z iPhone'em przez Wi-Fi: \"{}\" (UDID {})", info.name, info.udid);
    Ok(())
}

async fn install(config: &Config, interactive: bool) -> Result<(), Report> {
    let ipa = PathBuf::from(&config.ipa_path);
    if !ipa.is_file() {
        bail!("Nie znaleziono pliku IPA: {}", ipa.display());
    }
    let provider = device_provider(&config.device_ip)?;
    let device = IdeviceInfo::from_device(&provider)
        .await
        .context("iPhone nieosiągalny przez Wi-Fi (czy jest w tej samej sieci i ma włączony ekran?)")?;
    println!("iPhone: \"{}\"", device.name);

    let get_2fa_code = move |params: TwoFactorCallbackParams| async move {
        if !interactive {
            return Err::<TwoFactorCallbackResponse, Report>(
                report!("Apple wymaga kodu 2FA – zaloguj się raz ręcznie: `iphone-refresher install`")
                    .into(),
            );
        }
        if params.unknown {
            println!("Poprzednia metoda 2FA nie zadziałała.");
        }
        let code = prompt(
            "Kod 2FA (z urządzenia Apple; \"d\" = wyślij ponownie na urządzenia)",
            None,
        );
        Ok(if code == "d" {
            TwoFactorCallbackResponse::SendToDevices
        } else {
            TwoFactorCallbackResponse::SubmitCode(code)
        })
    };

    let mut account = AppleAccount::builder(&config.apple_id.to_lowercase())
        .anisette_provider(
            RemoteV3AnisetteProvider::default()?
                .set_serial_number("0".to_string())
                .set_storage(Box::new(FsStorage::new(state_dir("anisette"))))
                .set_client_info_override(Some(AnisetteClientInfo {
                    client_info: config.client_info.clone(),
                    user_agent: config.user_agent.clone(),
                }))
                .set_url(&config.anisette_url),
        )
        .login(&config.password, get_2fa_code)
        .await
        .context("Logowanie do Apple ID nie powiodło się")?;
    println!("Zalogowano do Apple ID.");

    let dev_session = DeveloperSession::from_account(&mut account)
        .await
        .context("Nie można otworzyć sesji deweloperskiej")?;

    // A free account can only hold a few development certificates. Never revoke one on our own –
    // that would break apps installed by other tools – but let a person choose when run by hand.
    let ask_which_to_revoke: MaxCertsCallbackBox = Box::new(move |certs: Vec<DevelopmentCertificate>| {
        Box::pin(async move {
            if !interactive {
                return Err::<Option<Vec<String>>, Report>(
                    report!("Osiągnięto limit certyfikatów – uruchom ręcznie `iphone-refresher install`")
                        .into(),
                );
            }
            println!("\nNa koncie jest już maksymalna liczba certyfikatów deweloperskich:");
            for (index, cert) in certs.iter().enumerate() {
                println!(
                    "  {}) {} | utworzony przez: {} | ważny do: {}",
                    index + 1,
                    cert.name.as_deref().unwrap_or("?"),
                    cert.machine_name.as_deref().unwrap_or("?"),
                    cert.expiration_date
                        .as_ref()
                        .map(|d| d.to_xml_format())
                        .unwrap_or_else(|| "?".to_string()),
                );
            }
            println!(
                "Unieważnienie certyfikatu wyłączy aplikacje, które zainstalowano nim przez inne narzędzie\n\
                 (np. iloader). Ta instalacja od razu je zastąpi."
            );
            let input = prompt("Numer certyfikatu do unieważnienia (Enter = anuluj)", None);
            let Some(cert) = input
                .parse::<usize>()
                .ok()
                .filter(|n| *n >= 1 && *n <= certs.len())
                .map(|n| &certs[n - 1])
            else {
                return Ok(None);
            };
            Ok(cert.serial_number.clone().map(|serial| vec![serial]))
        }) as MaxCertsCallbackFuture
    });

    let mut sideloader = SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(
        dev_session,
        config.apple_id.to_lowercase(),
    )
    .team_selection(TeamSelection::First)
    .max_certs_behavior(MaxCertsBehavior::Prompt(ask_which_to_revoke))
    .storage(Box::new(FsStorage::new(state_dir("sideloader"))))
    .machine_name("iphone-refresher".to_string())
    .extensions_behavior(ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::ReuseMain))
    .build();

    sideloader
        .install_app(
            &provider,
            ipa,
            false,
            None::<fn(f32) -> std::future::Ready<()>>,
            None,
        )
        .await
        .context("Podpisanie lub instalacja aplikacji nie powiodła się")?;
    record_success();
    println!("Gotowe: aplikacja zainstalowana i ważna przez kolejne 7 dni.");
    Ok(())
}

async fn auto() -> Result<(), Report> {
    if let Some(age) = seconds_since_last_success()
        && age < REFRESH_AFTER.as_secs()
    {
        println!("Odświeżanie niepotrzebne – ostatnio {}.", describe_age(age));
        return Ok(());
    }
    let config = load_config()?;
    match tokio::time::timeout(AUTO_TIMEOUT, install(&config, false)).await {
        Ok(result) => result,
        Err(_) => bail!("Przekroczono czas {} min – spróbuję przy następnym uruchomieniu", AUTO_TIMEOUT.as_secs() / 60),
    }
}

fn status() {
    match seconds_since_last_success() {
        Some(age) => {
            let remaining = (7 * 24 * 3600u64).saturating_sub(age);
            println!(
                "Ostatnie udane odświeżenie: {}. Podpis ważny jeszcze ok. {} dni {} godz.",
                describe_age(age),
                remaining / 86400,
                (remaining % 86400) / 3600
            );
        }
        None => println!("Brak zapisanego udanego odświeżenia."),
    }
}

async fn setup() -> Result<(), Report> {
    if !io::stdin().is_terminal() {
        bail!("`setup` trzeba uruchomić ręcznie w terminalu");
    }
    let previous = load_config().ok();
    let apple_id = prompt("Apple ID (e-mail)", previous.as_ref().map(|c| c.apple_id.as_str()));
    let password = rpassword::prompt_password("Hasło Apple ID (nie jest wyświetlane): ")
        .context("Nie można odczytać hasła")?;
    let device_ip = prompt(
        "Adres IP iPhone'a",
        Some(previous.as_ref().map(|c| c.device_ip.as_str()).unwrap_or("192.168.1.117")),
    );
    let ipa_path = prompt(
        "Ścieżka do pliku IPA",
        Some(
            previous
                .as_ref()
                .map(|c| c.ipa_path.as_str())
                .unwrap_or("/home/claude/ipa/RTSPViewer.ipa"),
        ),
    );
    let config = Config {
        apple_id,
        password,
        device_ip,
        ipa_path,
        anisette_url: previous.as_ref().map(|c| c.anisette_url.clone()).unwrap_or_else(default_anisette_url),
        client_info: previous.as_ref().map(|c| c.client_info.clone()).unwrap_or_else(default_client_info),
        user_agent: previous.as_ref().map(|c| c.user_agent.clone()).unwrap_or_else(default_user_agent),
    };
    save_config(&config)?;
    println!("Zapisano ustawienia w {}", config_path().display());
    install(&config, true).await
}

#[tokio::main]
async fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");
    isideload::init().expect("Failed to initialize error reporting");
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_ansi(io::stdout().is_terminal()) // no colour codes in the systemd journal
        .init();

    let command = std::env::args().nth(1).unwrap_or_default();
    let result = match command.as_str() {
        "check" => {
            let ip = std::env::args()
                .nth(2)
                .or_else(|| load_config().ok().map(|c| c.device_ip))
                .unwrap_or_else(|| "192.168.1.117".to_string());
            check(&ip).await
        }
        "setup" => setup().await,
        "install" => match load_config() {
            Ok(config) => install(&config, io::stdin().is_terminal()).await,
            Err(e) => Err(e),
        },
        "auto" => auto().await,
        "status" => {
            status();
            Ok(())
        }
        _ => {
            eprintln!("Użycie: iphone-refresher <check [ip] | setup | install | auto | status>");
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("BŁĄD: {e:?}");
            ExitCode::FAILURE
        }
    }
}
