use rmpv::Value;

use crate::error::{Error, Result};

/// Message type tag for a request, per the msgpack-rpc specification.
pub const KIND_REQUEST: u64 = 0;
/// Message type tag for a response.
pub const KIND_RESPONSE: u64 = 1;
/// Message type tag for a notification.
pub const KIND_NOTIFICATION: u64 = 2;

/// Represents one msgpack-rpc frame.
#[derive(Debug, Clone)]
pub enum Message {
    /// A call that expects a [`Message::Response`] carrying the same `msgid`.
    Request {
        msgid: u32,
        method: String,
        params: Vec<Value>,
    },
    /// The answer to a request. Exactly one of `error` and `result` is meaningful.
    Response {
        msgid: u32,
        error: Value,
        result: Value,
    },
    /// A fire-and-forget call. The peer never answers it.
    Notification { method: String, params: Vec<Value> },
}

impl Message {
    /// Decodes a frame from a raw msgpack value.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Protocol`] if the value does not match the
    /// msgpack-rpc array shape for any message kind.
    pub fn from_value(value: Value) -> Result<Self> {
        let parts = match value {
            Value::Array(parts) => parts,
            other => return Err(Error::protocol(format!("expected an array, got {other}"))),
        };

        let kind = parts
            .first()
            .and_then(Value::as_u64)
            .ok_or_else(|| Error::protocol("message has no type tag"))?;

        match (kind, parts.len()) {
            (KIND_REQUEST, 4) => Ok(Self::Request {
                msgid: field_u32(&parts[1], "msgid")?,
                method: field_string(&parts[2], "method")?,
                params: field_params(&parts[3])?,
            }),
            (KIND_RESPONSE, 4) => Ok(Self::Response {
                msgid: field_u32(&parts[1], "msgid")?,
                error: parts[2].clone(),
                result: parts[3].clone(),
            }),
            (KIND_NOTIFICATION, 3) => Ok(Self::Notification {
                method: field_string(&parts[1], "method")?,
                params: field_params(&parts[2])?,
            }),
            (kind, len) => Err(Error::protocol(format!(
                "unknown frame: type {kind} with {len} elements"
            ))),
        }
    }

    /// Encodes this frame back into a raw msgpack value.
    pub fn into_value(self) -> Value {
        match self {
            Self::Request {
                msgid,
                method,
                params,
            } => Value::Array(vec![
                Value::from(KIND_REQUEST),
                Value::from(msgid),
                Value::from(method),
                Value::Array(params),
            ]),
            Self::Response {
                msgid,
                error,
                result,
            } => Value::Array(vec![
                Value::from(KIND_RESPONSE),
                Value::from(msgid),
                error,
                result,
            ]),
            Self::Notification { method, params } => Value::Array(vec![
                Value::from(KIND_NOTIFICATION),
                Value::from(method),
                Value::Array(params),
            ]),
        }
    }

    /// Returns the method name for a request or notification.
    pub fn method(&self) -> Option<&str> {
        match self {
            Self::Request { method, .. } | Self::Notification { method, .. } => Some(method),
            Self::Response { .. } => None,
        }
    }
}

fn field_u32(value: &Value, what: &str) -> Result<u32> {
    value
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| Error::protocol(format!("{what} is not a u32: {value}")))
}

fn field_string(value: &Value, what: &str) -> Result<String> {
    value
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| Error::protocol(format!("{what} is not a string: {value}")))
}

fn field_params(value: &Value) -> Result<Vec<Value>> {
    match value {
        Value::Array(params) => Ok(params.clone()),
        other => Err(Error::protocol(format!("params is not an array: {other}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(message: Message) -> Message {
        Message::from_value(message.into_value()).expect("frame should round trip")
    }

    #[test]
    fn request_round_trips() {
        let decoded = round_trip(Message::Request {
            msgid: 7,
            method: "ping".into(),
            params: vec![Value::from(1)],
        });
        match decoded {
            Message::Request {
                msgid,
                method,
                params,
            } => {
                assert_eq!(msgid, 7);
                assert_eq!(method, "ping");
                assert_eq!(params, vec![Value::from(1)]);
            }
            other => panic!("expected a request, got {other:?}"),
        }
    }

    #[test]
    fn notification_round_trips() {
        let decoded = round_trip(Message::Notification {
            method: "call:state".into(),
            params: vec![],
        });
        assert_eq!(decoded.method(), Some("call:state"));
    }

    #[test]
    fn response_round_trips() {
        let decoded = round_trip(Message::Response {
            msgid: 3,
            error: Value::Nil,
            result: Value::from("ok"),
        });
        match decoded {
            Message::Response { msgid, result, .. } => {
                assert_eq!(msgid, 3);
                assert_eq!(result.as_str(), Some("ok"));
            }
            other => panic!("expected a response, got {other:?}"),
        }
    }

    #[test]
    fn wrong_arity_is_rejected() {
        let value = Value::Array(vec![Value::from(KIND_REQUEST), Value::from(1)]);
        assert!(Message::from_value(value).is_err());
    }

    #[test]
    fn non_array_is_rejected() {
        assert!(Message::from_value(Value::from("nope")).is_err());
    }
}
