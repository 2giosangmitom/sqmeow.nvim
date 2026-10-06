use rmpv::Value;

use sqmeow_rpc::client::Client;
use sqmeow_rpc::error::Result;

/// Typed Neovim calls over [`Client`].
#[derive(Clone)]
pub struct Nvim {
    client: Client,
}

impl Nvim {
    /// Wraps a client connected to Neovim.
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    /// Executes Lua in the editor without waiting for a result.
    pub fn exec_lua_notify(&self, code: &str, args: Vec<Value>) -> Result<()> {
        self.client
            .notify("nvim_exec_lua", vec![Value::from(code), Value::Array(args)])
    }

    /// Emits an event to the plugin's `sqmeow.rpc.client.dispatch` handler.
    pub fn emit(&self, event: &str, payload: Value) -> Result<()> {
        self.exec_lua_notify(DISPATCH, vec![Value::from(event), payload])
    }
}

/// The Lua entry point every event is funnelled through.
const DISPATCH: &str = "return require('sqmeow.rpc.client').dispatch(...)";
