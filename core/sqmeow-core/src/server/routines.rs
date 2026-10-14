//! Fetch stored routine definitions without executing them or adding query history.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::node::RoutineKind;

use super::{Core, Started};
use crate::server::args::Args;
use crate::server::payload::map;
use crate::server::session::ConnId;

#[derive(Debug)]
struct Request {
    conn_id: ConnId,
    schema: String,
    name: String,
    kind: RoutineKind,
    request_id: i64,
}

impl Request {
    fn parse(args: &Args) -> Result<Self, String> {
        let conn_id = args.conn_id("conn_id")?;
        let schema = args.string("schema")?;
        let name = args.string("name")?;
        if schema.is_empty() || name.is_empty() {
            return Err("routine schema and name must not be empty".to_owned());
        }
        let kind = match args.string("kind")?.as_str() {
            "function" => RoutineKind::Function,
            "procedure" => RoutineKind::Procedure,
            _ => return Err("routine kind must be function or procedure".to_owned()),
        };
        let request_id = args.integer("request_id")?;
        if request_id < 0 {
            return Err("request_id must not be negative".to_owned());
        }
        Ok(Self {
            conn_id,
            schema,
            name,
            kind,
            request_id,
        })
    }

    fn completion(&self, source: sqmeow_db::error::Result<Vec<String>>) -> Value {
        let mut payload = vec![
            ("conn_id", Value::from(self.conn_id)),
            ("schema", Value::from(self.schema.as_str())),
            ("name", Value::from(self.name.as_str())),
            ("kind", Value::from(self.kind.name())),
            ("request_id", Value::from(self.request_id)),
        ];
        match source {
            Ok(definitions) => payload.push(("source", Value::from(definitions.join("\n\n")))),
            Err(error) => payload.push(("error", Value::from(error.to_string()))),
        }
        map(payload)
    }
}

impl Core {
    /// Accept first, then send the fetched definition or failure through `routine:done`.
    pub(super) fn routine_source(self: Arc<Self>, args: &Args) -> Started {
        let request = Request::parse(args)?;
        let connection = self.connection(request.conn_id)?;
        let work = async move {
            let source = connection
                .backend
                .routine_source(&request.schema, &request.name, request.kind)
                .await;
            self.emit("routine:done", request.completion(source));
        };
        Ok((Value::Boolean(true), Box::pin(work)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(value: Value) -> Args {
        Args::from_params(&[value]).unwrap()
    }

    fn params() -> Vec<(&'static str, Value)> {
        vec![
            ("conn_id", Value::from(7)),
            ("schema", Value::from("public")),
            ("name", Value::from("do_work")),
            ("kind", Value::from("procedure")),
            ("request_id", Value::from(42)),
        ]
    }

    #[test]
    fn validates_identity_and_request_id() {
        let request = Request::parse(&args(map(params()))).unwrap();
        assert_eq!(request.kind, RoutineKind::Procedure);
        for (key, value) in [
            ("kind", Value::from("table")),
            ("name", Value::from("")),
            ("schema", Value::from("")),
            ("request_id", Value::from(-1)),
        ] {
            let fields = params()
                .into_iter()
                .map(|(k, v)| (k, if k == key { value.clone() } else { v }))
                .collect();
            assert!(Request::parse(&args(map(fields))).is_err());
        }
    }

    #[test]
    fn completion_echoes_identity_and_preserves_overloads() {
        let request = Request::parse(&args(map(params()))).unwrap();
        let payload = args(request.completion(Ok(vec![
            "first definition".into(),
            "second definition".into(),
        ])));
        assert_eq!(payload.integer("request_id").unwrap(), 42);
        assert_eq!(payload.string("schema").unwrap(), "public");
        assert_eq!(
            payload.string("source").unwrap(),
            "first definition\n\nsecond definition"
        );
        let error = args(request.completion(Err(sqmeow_db::error::Error::driver("hidden"))));
        assert_eq!(error.string("error").unwrap(), "hidden");
        assert!(error.opt_string("source").is_none());
    }
}
