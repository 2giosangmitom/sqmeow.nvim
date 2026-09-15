use std::io::{BufReader, BufWriter, Write};

use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};

use crate::message::Message;

/// Holds both halves of a framed msgpack-rpc stream.
pub struct Transport {
    /// Frames arriving from the peer.
    pub incoming: UnboundedReceiver<Message>,
    /// Frames on their way to the peer.
    pub outgoing: UnboundedSender<Message>,
}

/// Creates a transport speaking msgpack-rpc over stdin and stdout.
///
/// Spawns a reader thread blocking on stdin and a writer thread blocking
/// on stdout, each forwarding frames through channels.
pub fn stdio() -> Transport {
    let (incoming_tx, incoming) = mpsc::unbounded_channel();
    let (outgoing, outgoing_rx) = mpsc::unbounded_channel();

    spawn_reader(incoming_tx);
    spawn_writer(outgoing_rx);

    Transport { incoming, outgoing }
}

fn spawn_reader(sink: UnboundedSender<Message>) {
    let spawned = std::thread::Builder::new()
        .name("sqmeow-rpc-read".into())
        .spawn(move || {
            let mut reader = BufReader::new(std::io::stdin().lock());
            loop {
                match rmpv::decode::read_value(&mut reader) {
                    Ok(value) => match Message::from_value(value) {
                        // A malformed frame is dropped rather than fatal.
                        Err(error) => tracing::warn!(%error, "dropping malformed frame"),
                        Ok(message) => {
                            if sink.send(message).is_err() {
                                break;
                            }
                        }
                    },
                    Err(error) => {
                        if !is_eof(&error) {
                            tracing::error!(%error, "rpc read failed");
                        }
                        break;
                    }
                }
            }
            tracing::debug!("rpc reader stopped");
        });

    if let Err(error) = spawned {
        tracing::error!(%error, "could not spawn the rpc reader thread");
    }
}

fn spawn_writer(mut source: UnboundedReceiver<Message>) {
    let spawned = std::thread::Builder::new()
        .name("sqmeow-rpc-write".into())
        .spawn(move || {
            let mut writer = BufWriter::new(std::io::stdout().lock());
            while let Some(message) = source.blocking_recv() {
                if let Err(error) = rmpv::encode::write_value(&mut writer, &message.into_value()) {
                    tracing::error!(%error, "rpc write failed");
                    break;
                }
                // Flush per frame.
                if let Err(error) = writer.flush() {
                    tracing::error!(%error, "rpc flush failed");
                    break;
                }
            }
            tracing::debug!("rpc writer stopped");
        });

    if let Err(error) = spawned {
        tracing::error!(%error, "could not spawn the rpc writer thread");
    }
}

/// A clean hangup, meaning the editor closed the channel, rather than a real failure.
fn is_eof(error: &rmpv::decode::Error) -> bool {
    matches!(
        error,
        rmpv::decode::Error::InvalidMarkerRead(io) | rmpv::decode::Error::InvalidDataRead(io)
            if io.kind() == std::io::ErrorKind::UnexpectedEof
    )
}
