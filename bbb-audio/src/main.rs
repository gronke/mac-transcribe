mod audio_output;
mod bbb_client;
mod graphql;
mod webrtc_audio;

use anyhow::Result;
use clap::Parser;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(
    name = "bbb-audio",
    about = "BBB listen-only audio client.\n\n\
             Outputs raw s16le PCM (16 kHz mono) on stdout.\n\
             Outputs JSON speaker/meeting events on stderr, one per line."
)]
struct Args {
    /// BBB join URL
    #[arg()]
    join_url: Option<String>,

    /// BBB server URL (e.g. https://bbb.example.com/bigbluebutton)
    #[arg(long, requires_all = ["secret", "meeting_id"])]
    server: Option<String>,

    /// BBB shared secret for API authentication
    #[arg(long, requires_all = ["server", "meeting_id"])]
    secret: Option<String>,

    /// BBB meeting ID (used with --server and --secret)
    #[arg(long, requires_all = ["server", "secret"])]
    meeting_id: Option<String>,

    /// Display name when joining via --server/--secret (default: Transcriber)
    #[arg(long, default_value = "Transcriber")]
    name: String,

    /// Output sample rate in Hz (must be an Opus-supported rate)
    #[arg(long, default_value = "16000")]
    sample_rate: u32,

    /// Record audio to a WAV file instead of streaming PCM to stdout
    #[arg(long, value_name = "PATH")]
    record: Option<std::path::PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    if args.join_url.is_none() && args.server.is_none() {
        anyhow::bail!("Provide either a join URL or --server, --secret, and --meeting-id.");
    }

    // 1. Authenticate with BBB
    eprintln!("Connecting to BBB meeting...");
    let session = if let Some(url) = &args.join_url {
        bbb_client::join_via_url(url).await?
    } else {
        bbb_client::join_via_secret(
            args.server.as_deref().unwrap(),
            args.secret.as_deref().unwrap(),
            args.meeting_id.as_deref().unwrap(),
            &args.name,
        )
        .await?
    };
    eprintln!("Session established (host: {})", session.server_host);

    // 2. Connect to GraphQL for speaker tracking and meeting info
    let mut gql = graphql::GraphQLClient::connect(&session).await?;
    let meeting_info = gql.fetch_meeting_info().await?;
    eprintln!(
        "Joined meeting: {} (voice: {})",
        meeting_info.meeting_id, meeting_info.voice_conf
    );

    // Emit meeting_info event on stderr
    audio_output::emit_event(&serde_json::json!({
        "event": "meeting_info",
        "meetingId": meeting_info.meeting_id,
        "voiceConf": meeting_info.voice_conf,
    }));

    // 3. Start speaker tracking in background (emits events to stderr)
    let speaker_handle = tokio::spawn(async move {
        if let Err(e) = gql.subscribe_speakers().await {
            eprintln!("Speaker subscription ended: {e}");
        }
    });

    // 4. Channel for decoded PCM audio from WebRTC -> stdout writer
    let (pcm_tx, pcm_rx) = mpsc::channel::<Vec<i16>>(256);

    // 5. Start audio output on a blocking thread
    let record_path = args.record;
    let sample_rate = args.sample_rate;
    let output_handle = tokio::task::spawn_blocking(move || {
        if let Some(path) = record_path {
            audio_output::write_pcm_wav(pcm_rx, &path, sample_rate);
        } else {
            audio_output::write_pcm_stdout(pcm_rx);
        }
    });

    // 6. Connect to SFU and start WebRTC audio reception
    let result = webrtc_audio::run(&session, &meeting_info, pcm_tx, args.sample_rate).await;

    // 7. Cleanup
    audio_output::emit_event(&serde_json::json!({"event": "ended"}));
    speaker_handle.abort();
    output_handle.abort();

    result
}
