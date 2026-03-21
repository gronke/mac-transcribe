use std::sync::Arc;

use anyhow::{anyhow, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::{mpsc, Notify};
use tokio_tungstenite::tungstenite::Message;

use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::APIBuilder;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_connection_state::RTCIceConnectionState;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::RTPCodecType;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::RTCRtpTransceiverInit;
use webrtc::track::track_remote::TrackRemote;

use crate::bbb_client::{BbbSession, TlsConfig};
use crate::graphql::MeetingInfo;

/// Full WebRTC lifecycle: create PeerConnection, signal via SFU, decode audio.
pub async fn run(
    session: &BbbSession,
    meeting_info: &MeetingInfo,
    pcm_tx: mpsc::Sender<Vec<i16>>,
    sample_rate: u32,
    tls: &TlsConfig,
) -> Result<()> {
    // --- webrtc-rs setup ---

    let mut media = MediaEngine::default();
    media.register_default_codecs()?;

    let mut registry = Registry::new();
    registry = register_default_interceptors(registry, &mut media)?;

    let api = APIBuilder::new()
        .with_media_engine(media)
        .with_interceptor_registry(registry)
        .build();

    let config = RTCConfiguration {
        ice_servers: vec![RTCIceServer {
            urls: vec!["stun:stun.l.google.com:19302".to_owned()],
            ..Default::default()
        }],
        ..Default::default()
    };
    let pc = Arc::new(api.new_peer_connection(config).await?);

    // recv-only audio transceiver
    pc.add_transceiver_from_kind(
        RTPCodecType::Audio,
        Some(RTCRtpTransceiverInit {
            direction: RTCRtpTransceiverDirection::Recvonly,
            send_encodings: vec![],
        }),
    )
    .await?;

    // --- on_track: Opus RTP -> PCM ---

    {
        let tx = pcm_tx.clone();
        pc.on_track(Box::new(move |track, _rx, _tx| {
            let pcm = tx.clone();
            Box::pin(async move {
                tokio::spawn(decode_track(track, pcm, sample_rate));
            })
        }));
    }

    // --- ICE candidate forwarding (PC -> SFU) ---

    let (ice_tx, mut ice_rx) = mpsc::channel::<Value>(32);
    {
        let tx = ice_tx.clone();
        pc.on_ice_candidate(Box::new(move |candidate| {
            let tx = tx.clone();
            Box::pin(async move {
                if let Some(c) = candidate {
                    if let Ok(j) = c.to_json() {
                        let _ = tx
                            .send(json!({
                                "id": "iceCandidate",
                                "type": "audio",
                                "role": "recv",
                                "candidate": {
                                    "candidate": j.candidate,
                                    "sdpMid": j.sdp_mid,
                                    "sdpMLineIndex": j.sdp_mline_index,
                                }
                            }))
                            .await;
                    }
                }
            })
        }));
    }
    // Drop our sender so the channel closes when the callback's clone is dropped.
    drop(ice_tx);

    // --- ICE connection state -> done signal ---

    let done = Arc::new(Notify::new());
    {
        let done = done.clone();
        pc.on_ice_connection_state_change(Box::new(move |state| {
            let done = done.clone();
            Box::pin(async move {
                if matches!(
                    state,
                    RTCIceConnectionState::Disconnected
                        | RTCIceConnectionState::Failed
                        | RTCIceConnectionState::Closed
                ) {
                    done.notify_one();
                }
            })
        }));
    }

    // --- SDP offer ---

    let offer = pc.create_offer(None).await?;
    let offer_sdp = offer.sdp.clone();
    pc.set_local_description(offer).await?;

    // --- SFU WebSocket ---

    let token = urlencoding::encode(&session.session_token);
    let sfu_url = format!(
        "wss://{}/bbb-webrtc-sfu?sessionToken={token}",
        session.server_host
    );
    let connector = tls.native_tls_connector()?;
    let (ws, _) = tokio_tungstenite::connect_async_tls_with_config(
        &sfu_url,
        None,
        false,
        Some(tokio_tungstenite::Connector::NativeTls(connector)),
    )
    .await
    .map_err(|e| anyhow!("SFU connect: {e}"))?;
    let (mut ws_tx, mut ws_rx) = ws.split();

    // Send start message
    let start = json!({
        "id": "start",
        "type": "audio",
        "role": "recv",
        "meetingId": meeting_info.meeting_id,
        "voiceBridge": meeting_info.voice_conf,
        "sdpOffer": offer_sdp,
        "mediaServer": "mediasoup",
    });
    ws_tx.send(Message::Text(start.to_string())).await?;

    // Wait for SDP answer
    let answer_sdp = wait_for_answer(&mut ws_rx).await?;
    pc.set_remote_description(RTCSessionDescription::answer(answer_sdp)?)
        .await?;

    eprintln!("WebRTC audio connected. Streaming PCM to stdout...");

    // --- message loop: ICE candidates + done ---

    loop {
        tokio::select! {
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(Message::Text(t))) => {
                        handle_sfu_message(&t, &pc).await;
                    }
                    None | Some(Err(_)) => break,
                    _ => {}
                }
            }
            ice = ice_rx.recv() => {
                if let Some(msg) = ice {
                    let _ = ws_tx.send(Message::Text(msg.to_string())).await;
                }
            }
            _ = done.notified() => break,
        }
    }

    pc.close().await?;
    Ok(())
}

// -- SFU helpers --

type WsRead = futures_util::stream::SplitStream<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
>;

async fn wait_for_answer(rx: &mut WsRead) -> Result<String> {
    while let Some(msg) = rx.next().await {
        if let Ok(Message::Text(t)) = msg {
            if let Ok(j) = serde_json::from_str::<Value>(&t) {
                if j["id"] == "startResponse" {
                    if let Some(sdp) = j["sdpAnswer"].as_str() {
                        return Ok(sdp.to_owned());
                    }
                }
                if j["id"] == "error" {
                    return Err(anyhow!("SFU error: {}", j["message"]));
                }
            }
        }
    }
    Err(anyhow!("SFU WebSocket closed before answer"))
}

async fn handle_sfu_message(text: &str, pc: &Arc<RTCPeerConnection>) {
    let Ok(j) = serde_json::from_str::<Value>(text) else {
        return;
    };
    if j["id"] == "iceCandidate" {
        if let Some(c) = j.get("candidate") {
            let init = RTCIceCandidateInit {
                candidate: c["candidate"].as_str().unwrap_or("").to_owned(),
                sdp_mid: c["sdpMid"].as_str().map(str::to_owned),
                sdp_mline_index: c["sdpMLineIndex"].as_u64().map(|n| n as u16),
                ..Default::default()
            };
            let _ = pc.add_ice_candidate(init).await;
        }
    }
}

// -- Opus decode --

async fn decode_track(track: Arc<TrackRemote>, tx: mpsc::Sender<Vec<i16>>, sample_rate: u32) {
    if let Err(e) = decode_track_inner(track, tx, sample_rate).await {
        eprintln!("Audio track ended: {e}");
    }
}

async fn decode_track_inner(
    track: Arc<TrackRemote>,
    tx: mpsc::Sender<Vec<i16>>,
    sample_rate: u32,
) -> Result<()> {
    let sr = match sample_rate {
        8000 => audiopus::SampleRate::Hz8000,
        12000 => audiopus::SampleRate::Hz12000,
        24000 => audiopus::SampleRate::Hz24000,
        48000 => audiopus::SampleRate::Hz48000,
        _ => audiopus::SampleRate::Hz16000,
    };

    let mut decoder = audiopus::coder::Decoder::new(sr, audiopus::Channels::Mono)?;

    // Opus supports frames up to 120 ms; allocate accordingly.
    let max_samples = (sample_rate as usize) * 120 / 1000;
    let mut pcm_buf = vec![0i16; max_samples];

    loop {
        let (pkt, _) = track.read_rtp().await.map_err(|e| anyhow!("{e}"))?;

        if pkt.payload.is_empty() {
            continue;
        }

        let Ok(packet) = audiopus::packet::Packet::try_from(&pkt.payload[..]) else {
            continue;
        };
        let Ok(output) = audiopus::MutSignals::try_from(&mut pcm_buf[..]) else {
            continue;
        };
        match decoder.decode(Some(packet), output, false) {
            Ok(n) if n > 0 => {
                if tx.send(pcm_buf[..n].to_vec()).await.is_err() {
                    break;
                }
            }
            _ => {}
        }
    }

    Ok(())
}
