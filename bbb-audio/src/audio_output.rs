use std::fs::File;
use std::io::{self, BufWriter, Seek, SeekFrom, Write};
use std::path::Path;
use tokio::sync::mpsc;

/// Read decoded PCM samples from the channel and write them as s16le to stdout.
/// Runs on a blocking thread via `spawn_blocking`.
pub fn write_pcm_stdout(mut rx: mpsc::Receiver<Vec<i16>>) {
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());

    while let Some(samples) = rx.blocking_recv() {
        for sample in &samples {
            if out.write_all(&sample.to_le_bytes()).is_err() {
                return;
            }
        }
        // Flush after each packet to keep latency low for the pipe reader.
        if out.flush().is_err() {
            return;
        }
    }

    let _ = out.flush();
}

/// Read decoded PCM samples from the channel and write them as a WAV file.
/// Runs on a blocking thread via `spawn_blocking`.
pub fn write_pcm_wav(mut rx: mpsc::Receiver<Vec<i16>>, path: &Path, sample_rate: u32) {
    let file = match File::create(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("Failed to create WAV file: {e}");
            return;
        }
    };
    let mut out = BufWriter::new(file);

    // Write 44-byte WAV header with placeholder sizes.
    let byte_rate = sample_rate * 2; // mono, 16-bit
    let header: [u8; 44] = {
        let mut h = [0u8; 44];
        h[0..4].copy_from_slice(b"RIFF");
        // h[4..8] = chunk size (patched later)
        h[8..12].copy_from_slice(b"WAVE");
        h[12..16].copy_from_slice(b"fmt ");
        h[16..20].copy_from_slice(&16u32.to_le_bytes()); // subchunk1 size
        h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM format
        h[22..24].copy_from_slice(&1u16.to_le_bytes()); // mono
        h[24..28].copy_from_slice(&sample_rate.to_le_bytes());
        h[28..32].copy_from_slice(&byte_rate.to_le_bytes());
        h[32..34].copy_from_slice(&2u16.to_le_bytes()); // block align
        h[34..36].copy_from_slice(&16u16.to_le_bytes()); // bits per sample
        h[36..40].copy_from_slice(b"data");
        // h[40..44] = data size (patched later)
        h
    };
    if out.write_all(&header).is_err() {
        eprintln!("Failed to write WAV header");
        return;
    }

    eprintln!("Recording to {}", path.display());

    let mut data_bytes: u32 = 0;
    while let Some(samples) = rx.blocking_recv() {
        for sample in &samples {
            if out.write_all(&sample.to_le_bytes()).is_err() {
                eprintln!("WAV write error");
                return;
            }
        }
        data_bytes = data_bytes.saturating_add((samples.len() * 2) as u32);
    }

    // Patch the two size fields in the WAV header.
    let _ = out.flush();
    if let Ok(inner) = out.into_inner() {
        let mut file = inner;
        let chunk_size = data_bytes + 36;
        let _ = file.seek(SeekFrom::Start(4));
        let _ = file.write_all(&chunk_size.to_le_bytes());
        let _ = file.seek(SeekFrom::Start(40));
        let _ = file.write_all(&data_bytes.to_le_bytes());
        let _ = file.flush();
        eprintln!("Saved {} bytes of audio to {}", data_bytes, path.display());
    }
}

/// Write a JSON event to stderr (one line, newline-terminated).
pub fn emit_event(event: &serde_json::Value) {
    eprintln!("{event}");
}
