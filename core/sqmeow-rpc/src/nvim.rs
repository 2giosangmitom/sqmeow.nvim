use rmpv::Value;

use crate::client::Client;
use crate::error::Result;

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
}

/// The Lua entry point every event is funnelled through.
const DISPATCH: &str = "return require('sqmeow.rpc').dispatch(...)";
