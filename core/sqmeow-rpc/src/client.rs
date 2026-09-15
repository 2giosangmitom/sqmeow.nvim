use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};

use rmpv::Value;
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::oneshot;

use crate::error::{Error, Result};
use crate::message::Message;

type Pending = Arc<Mutex<HashMap<u32, oneshot::Sender<Result<Value>>>>>;

/// Sends requests and notifications to the peer.
///
///
/// Holds the outbound channel and the table of in-flight requests. Cloning
/// shares the same underlying channel and request table.
#[derive(Clone)]
pub struct Client {
    outgoing: UnboundedSender<Message>,
    pending: Pending,
    next_id: Arc<AtomicU32>,
}

impl Client {
    /// Creates a client from the outbound channel of a [`crate::Transport`].
    pub fn new(outgoing: UnboundedSender<Message>) -> Self {
        Self {
            outgoing,
            pending: Pending::default(),
            next_id: Arc::new(AtomicU32::new(1)),
        }
    }

    /// Calls the peer and waits for its answer.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Closed`] if the peer hung up or the writer task
    /// disappeared before a response arrived, or [`Error::Remote`] if the
    /// peer answered with an error payload.
    pub async fn request(&self, method: impl Into<String>, params: Vec<Value>) -> Result<Value> {
        let msgid = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .expect("pending map poisoned")
            .insert(msgid, tx);

        let sent = self.send(Message::Request {
            msgid,
            method: method.into(),
            params,
        });
        if let Err(error) = sent {
            self.pending
                .lock()
                .expect("pending map poisoned")
                .remove(&msgid);
            return Err(error);
        }

        rx.await.map_err(|_| Error::Closed)?
    }

    /// Notifies the peer without waiting for a response.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Closed`] if the outbound channel is gone.
    pub fn notify(&self, method: impl Into<String>, params: Vec<Value>) -> Result<()> {
        self.send(Message::Notification {
            method: method.into(),
            params,
        })
    }

    /// Responds to a request the peer made.
    ///
    /// Sends a msgpack-rpc response frame with the given `msgid`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Closed`] if the peer is gone.
    pub fn respond(&self, msgid: u32, outcome: std::result::Result<Value, String>) -> Result<()> {
        let (error, result) = match outcome {
            Ok(value) => (Value::Nil, value),
            Err(message) => (Value::from(message), Value::Nil),
        };
        self.send(Message::Response {
            msgid,
            error,
            result,
        })
    }

    /// Hand an incoming response to whoever is waiting on it.
    pub(crate) fn resolve(&self, msgid: u32, error: Value, result: Value) {
        let waiter = self
            .pending
            .lock()
            .expect("pending map poisoned")
            .remove(&msgid);

        match waiter {
            Some(waiter) => {
                let outcome = if error.is_nil() {
                    Ok(result)
                } else {
                    Err(Error::remote(&error))
                };
                // A dropped receiver means the caller gave up first, which is not our problem.
                let _ = waiter.send(outcome);
            }
            None => tracing::warn!(msgid, "response for an unknown request"),
        }
    }

    /// Fail every in-flight request. Called once the peer has hung up.
    pub(crate) fn close(&self) {
        let waiters = std::mem::take(&mut *self.pending.lock().expect("pending map poisoned"));
        for (_, waiter) in waiters {
            let _ = waiter.send(Err(Error::Closed));
        }
    }

    fn send(&self, message: Message) -> Result<()> {
        self.outgoing.send(message).map_err(|_| Error::Closed)
    }
}
