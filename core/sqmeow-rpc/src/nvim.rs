use rmpv::Value;

use crate::client::Client;
use crate::error::Result;

/// One queued Neovim API call: a method name and its positional arguments.
#[derive(Debug, Clone)]
pub struct ApiCall {
    pub method: String,
    pub args: Vec<Value>,
}

impl ApiCall {
    /// Build a call by hand.
    pub fn new(method: impl Into<String>, args: Vec<Value>) -> Self {
        Self {
            method: method.into(),
            args,
        }
    }

    /// Replace lines `start..end` of a buffer. Pass `-1` as `end` to mean the last line.
    pub fn buf_set_lines(buf: i64, start: i64, end: i64, lines: Vec<String>) -> Self {
        Self::new(
            "nvim_buf_set_lines",
            vec![
                Value::from(buf),
                Value::from(start),
                Value::from(end),
                // strict_indexing off: the buffer may have shrunk since we measured it.
                Value::from(false),
                Value::Array(lines.into_iter().map(Value::from).collect()),
            ],
        )
    }

    fn into_value(self) -> Value {
        Value::Array(vec![Value::from(self.method), Value::Array(self.args)])
    }
}

/// The Neovim side of the connection, as a small typed surface over [`Client`].
#[derive(Clone)]
pub struct Nvim {
    client: Client,
}

impl Nvim {
    /// Wrap a client that is connected to Neovim.
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    /// The untyped client underneath, for calls this wrapper does not cover.
    pub fn client(&self) -> &Client {
        &self.client
    }

    /// Run Lua in the editor and wait for its value.
    pub async fn exec_lua(&self, code: &str, args: Vec<Value>) -> Result<Value> {
        self.client
            .request("nvim_exec_lua", vec![Value::from(code), Value::Array(args)])
            .await
    }

    /// Run Lua in the editor without waiting.
    pub fn exec_lua_notify(&self, code: &str, args: Vec<Value>) -> Result<()> {
        self.client
            .notify("nvim_exec_lua", vec![Value::from(code), Value::Array(args)])
    }

    /// Push an event at the plugin.
    ///
    /// Always a notification. If the core waited for the editor to acknowledge each event, a
    /// stalled UI would stall the core, and a query already in flight would stall with it.
    pub fn emit(&self, event: &str, payload: Value) -> Result<()> {
        self.exec_lua_notify(DISPATCH, vec![Value::from(event), payload])
    }

    /// Run a batch of API calls in one round trip.
    ///
    /// This is how a result page reaches a buffer: the lines and every highlight that decorates
    /// them travel together, so painting a page costs one message rather than hundreds.
    pub async fn call_atomic(&self, calls: Vec<ApiCall>) -> Result<Value> {
        let calls = calls.into_iter().map(ApiCall::into_value).collect();
        self.client
            .request("nvim_call_atomic", vec![Value::Array(calls)])
            .await
    }
}

/// The Lua entry point every event is funnelled through.
const DISPATCH: &str = "return require('sqmeow.rpc').dispatch(...)";
