use anyhow::{anyhow, Result};
use sha2::{Digest, Sha256};
use url::Url;

pub struct BbbSession {
    pub session_token: String,
    pub server_host: String,
    #[allow(dead_code)] // Retained for callers; not consumed internally.
    pub meeting_id: String,
}

/// Follow redirects from a join URL (possibly via Nextcloud or similar) until
/// we reach a BBB redirect containing `sessionToken`.  Also accepts URLs that
/// already carry a `sessionToken` (e.g. pasted from the browser address bar).
pub async fn join_via_url(join_url: &str) -> Result<BbbSession> {
    let mut current_url = Url::parse(join_url)?;

    // If the URL already contains a sessionToken, use it directly.
    if let Some(session) = extract_session(&current_url) {
        return Ok(session);
    }

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;

    let mut meeting_id = String::new();

    for _ in 0..10 {
        // Pick up meetingID from whichever URL in the chain has it.
        if meeting_id.is_empty() {
            if let Some((_, v)) = current_url.query_pairs().find(|(k, _)| k == "meetingID") {
                meeting_id = v.to_string();
            }
        }

        let resp = client.get(current_url.as_str()).send().await?;

        let location = match resp.headers().get("location").and_then(|v| v.to_str().ok()) {
            Some(loc) => loc.to_string(),
            None => {
                anyhow::bail!(
                    "No redirect from {}. \
                     The meeting may not exist or the link may have expired.",
                    current_url
                );
            }
        };

        let location_url = Url::parse(&location).or_else(|_| current_url.join(&location))?;

        // If this redirect carries a sessionToken, we've reached BBB's final redirect.
        // The BBB server is the host that issued this redirect.
        if let Some((_, token)) = location_url
            .query_pairs()
            .find(|(k, _)| k == "sessionToken")
        {
            let server_host = current_url
                .host_str()
                .ok_or_else(|| anyhow!("No host in BBB URL"))?
                .to_string();

            return Ok(BbbSession {
                session_token: token.to_string(),
                server_host,
                meeting_id,
            });
        }

        current_url = location_url;
    }

    anyhow::bail!("Too many redirects without finding a sessionToken")
}

/// If the URL already carries a sessionToken, build a session from it directly.
fn extract_session(url: &Url) -> Option<BbbSession> {
    let token = url
        .query_pairs()
        .find(|(k, _)| k == "sessionToken")
        .map(|(_, v)| v.to_string())?;
    let host = url.host_str()?.to_string();
    let meeting_id = url
        .query_pairs()
        .find(|(k, _)| k == "meetingID")
        .map(|(_, v)| v.to_string())
        .unwrap_or_default();
    Some(BbbSession {
        session_token: token,
        server_host: host,
        meeting_id,
    })
}

/// Join using server URL, shared secret, and meeting ID (generates a join URL
/// with SHA-256 checksum, then follows the redirect).
pub async fn join_via_secret(
    server: &str,
    secret: &str,
    meeting_id: &str,
    name: &str,
) -> Result<BbbSession> {
    let encoded_name = urlencoding::encode(name);
    let encoded_id = urlencoding::encode(meeting_id);
    let params = format!("fullName={encoded_name}&meetingID={encoded_id}&role=VIEWER");
    let checksum = sha256_checksum("join", &params, secret);

    let base = server.trim_end_matches('/');
    let join_url = format!("{base}/api/join?{params}&checksum={checksum}");

    join_via_url(&join_url).await
}

fn sha256_checksum(api_call: &str, params: &str, secret: &str) -> String {
    let input = format!("{api_call}{params}{secret}");
    let hash = Sha256::digest(input.as_bytes());
    hash.iter().map(|b| format!("{b:02x}")).collect()
}
