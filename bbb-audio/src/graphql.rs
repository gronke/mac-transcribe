use anyhow::{anyhow, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

use crate::audio_output;
use crate::bbb_client::{BbbSession, TlsConfig};

pub struct MeetingInfo {
    pub meeting_id: String,
    pub voice_conf: String,
}

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

pub struct GraphQLClient {
    ws: WsStream,
    next_id: u32,
}

impl GraphQLClient {
    /// Connect to BBB's Hasura GraphQL endpoint (graphql-transport-ws protocol).
    pub async fn connect(session: &BbbSession, tls: &TlsConfig) -> Result<Self> {
        let request = http::Request::builder()
            .uri(format!("wss://{}/graphql", session.server_host))
            .header("Sec-WebSocket-Protocol", "graphql-transport-ws")
            .body(())?;

        let connector = tls.native_tls_connector()?;
        let (ws, _) = tokio_tungstenite::connect_async_tls_with_config(
            request,
            None,
            false,
            Some(tokio_tungstenite::Connector::NativeTls(connector)),
        )
        .await
        .map_err(|e| anyhow!("GraphQL WebSocket connect failed: {e}"))?;

        let mut client = Self { ws, next_id: 1 };

        // connection_init with session token
        client
            .send_json(&json!({
                "type": "connection_init",
                "payload": {
                    "headers": {
                        "X-Session-Token": session.session_token,
                    }
                }
            }))
            .await?;

        let ack = client.recv_json().await?;
        if ack.get("type").and_then(|v| v.as_str()) != Some("connection_ack") {
            return Err(anyhow!("Expected connection_ack, got: {ack}"));
        }

        Ok(client)
    }

    /// Fetch meeting info (internalMeetingId, voiceConf) via a one-shot subscription.
    pub async fn fetch_meeting_info(&mut self) -> Result<MeetingInfo> {
        let id = self.next_id();
        self.subscribe(
            &id,
            "subscription { meeting { meetingId voiceSettings { voiceConf } } }",
        )
        .await?;

        let data = self.recv_subscription_data(&id).await?;

        // Complete the subscription after getting the first snapshot.
        self.send_json(&json!({"id": id, "type": "complete"}))
            .await?;

        let meetings = data["meeting"]
            .as_array()
            .ok_or_else(|| anyhow!("No meeting array in response"))?;
        let meeting = meetings
            .first()
            .ok_or_else(|| anyhow!("Empty meeting array"))?;
        let meeting_id = meeting["meetingId"]
            .as_str()
            .ok_or_else(|| anyhow!("No meetingId"))?
            .to_owned();
        let voice_conf = meeting["voiceSettings"]["voiceConf"]
            .as_str()
            .ok_or_else(|| anyhow!("No voiceConf"))?
            .to_owned();

        Ok(MeetingInfo {
            meeting_id,
            voice_conf,
        })
    }

    /// Subscribe to user_voice and emit speaker change events to stderr.
    /// Runs until the subscription completes or the WebSocket closes.
    pub async fn subscribe_speakers(&mut self) -> Result<()> {
        let id = self.next_id();
        self.subscribe(
            &id,
            "subscription { user_voice { userId talking user { name } } }",
        )
        .await?;

        loop {
            let msg = self.recv_json().await?;
            match msg.get("type").and_then(|v| v.as_str()) {
                Some("next") if msg.get("id").and_then(|v| v.as_str()) == Some(&id) => {
                    let (name, user_id) = parse_speaker(&msg);
                    audio_output::emit_event(&json!({
                        "event": "speaker",
                        "name": name,
                        "userId": user_id,
                    }));
                }
                Some("ping") => {
                    self.send_json(&json!({"type": "pong"})).await?;
                }
                Some("complete") => break,
                _ => {}
            }
        }

        Ok(())
    }

    // -- helpers --

    fn next_id(&mut self) -> String {
        let id = self.next_id.to_string();
        self.next_id += 1;
        id
    }

    async fn subscribe(&mut self, id: &str, query: &str) -> Result<()> {
        self.send_json(&json!({
            "id": id,
            "type": "subscribe",
            "payload": {"query": query},
        }))
        .await
    }

    async fn send_json(&mut self, value: &Value) -> Result<()> {
        self.ws
            .send(Message::Text(value.to_string()))
            .await
            .map_err(|e| anyhow!("WS send: {e}"))
    }

    async fn recv_json(&mut self) -> Result<Value> {
        loop {
            match self.ws.next().await {
                Some(Ok(Message::Text(text))) => return Ok(serde_json::from_str(&text)?),
                Some(Ok(Message::Ping(_))) => {} // tungstenite handles pong automatically
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(anyhow!("WS recv: {e}")),
                None => return Err(anyhow!("WebSocket closed")),
            }
        }
    }

    async fn recv_subscription_data(&mut self, id: &str) -> Result<Value> {
        loop {
            let msg = self.recv_json().await?;
            match msg.get("type").and_then(|v| v.as_str()) {
                Some("ping") => {
                    self.send_json(&json!({"type": "pong"})).await?;
                }
                Some("next") if msg.get("id").and_then(|v| v.as_str()) == Some(id) => {
                    if let Some(data) = msg.get("payload").and_then(|p| p.get("data")) {
                        return Ok(data.clone());
                    }
                }
                Some("error") => return Err(anyhow!("Subscription error: {msg}")),
                _ => continue,
            }
        }
    }
}

/// Extract the currently talking user from a `user_voice` subscription payload.
/// Returns (name, userId) — both None if nobody is talking.
fn parse_speaker(msg: &Value) -> (Option<&str>, Option<&str>) {
    let voices = msg
        .get("payload")
        .and_then(|p| p.get("data"))
        .and_then(|d| d.get("user_voice"))
        .and_then(|v| v.as_array());

    let Some(voices) = voices else {
        return (None, None);
    };

    for voice in voices {
        if voice.get("talking").and_then(|t| t.as_bool()) == Some(true) {
            let name = voice
                .get("user")
                .and_then(|u| u.get("name"))
                .and_then(|n| n.as_str());
            let user_id = voice.get("userId").and_then(|u| u.as_str());
            return (name, user_id);
        }
    }

    (None, None)
}
