//! Table-level outgoing and incoming foreign keys, without reading table rows.

use std::sync::Arc;

use rmpv::Value;
use sqmeow_db::adapter::Dialect;
use sqmeow_db::error::Error as DbError;
use sqmeow_db::node::RelationshipNode;

use super::{Core, Started};
use crate::server::args::Args;
use crate::server::payload::{map, strings};
use crate::server::schema::default_schema;
use crate::server::session::ConnId;

#[derive(Debug)]
struct Request {
    conn_id: ConnId,
    schema: String,
    relation: String,
    request_id: i64,
}

impl Request {
    fn parse(args: &Args) -> Result<Self, String> {
        let conn_id = args.conn_id("conn_id")?;
        // An empty schema asks for the default, but malformed or missing values do not.
        let schema = args.string("schema")?;
        let relation = args.string("relation")?;
        if relation.trim().is_empty() {
            return Err("`relation` must not be empty".to_owned());
        }
        let request_id = args.integer("request_id")?;
        if request_id < 0 {
            return Err("`request_id` must not be negative".to_owned());
        }
        Ok(Self {
            conn_id,
            schema,
            relation,
            request_id,
        })
    }

    fn completion(&self, result: Result<Vec<RelationshipNode>, DbError>) -> Value {
        // Echo the requested identity, not the resolved schema. Lua uses it to discard
        // late responses when the selected table changes or its connection closes.
        let mut payload = vec![
            ("conn_id", Value::from(self.conn_id)),
            ("schema", Value::from(self.schema.as_str())),
            ("relation", Value::from(self.relation.as_str())),
            ("request_id", Value::from(self.request_id)),
        ];
        match result {
            Ok(relationships) => payload.push((
                "relationships",
                Value::Array(relationships.into_iter().map(relationship_node).collect()),
            )),
            // Unsupported backends must remain errors, not look like tables without keys.
            Err(error) => payload.push(("error", Value::from(error.to_string()))),
        }
        map(payload)
    }
}

impl Core {
    /// Read table relationships and report them through `relationships:done`.
    pub(super) fn relationships(self: Arc<Self>, args: &Args) -> Started {
        let request = Request::parse(args)?;
        let connection = self.connection(request.conn_id)?;
        let work = async move {
            let backend = &connection.backend;
            let read = async {
                let schema = match request.schema.as_str() {
                    "" => default_schema(backend).await?,
                    named => named.to_owned(),
                };
                let relationships = backend.relationships(&schema, &request.relation).await?;
                Ok::<_, DbError>((schema, relationships))
            };
            let payload = match read.await {
                Ok((schema, relationships)) => {
                    let (schema, relation) = resolved_identity(
                        backend.dialect(),
                        &schema,
                        &request.relation,
                        &relationships,
                    );
                    let mut payload = request.completion(Ok(relationships));
                    if let Value::Map(fields) = &mut payload {
                        fields.push((Value::from("resolved_schema"), Value::from(schema)));
                        fields.push((Value::from("resolved_relation"), Value::from(relation)));
                    }
                    payload
                }
                Err(error) => request.completion(Err(error)),
            };
            self.emit("relationships:done", payload);
        };
        Ok((Value::Boolean(true), Box::pin(work)))
    }
}

/// Catalog endpoints retain their spelling even when the database resolved an unquoted or
/// case-insensitive request. Keep that identity separate from the echoed request identity.
fn resolved_identity(
    dialect: Dialect,
    schema: &str,
    relation: &str,
    relationships: &[RelationshipNode],
) -> (String, String) {
    let endpoints = || {
        relationships.iter().flat_map(|key| {
            [
                (key.source_schema.as_str(), key.source_relation.as_str()),
                (key.target_schema.as_str(), key.target_relation.as_str()),
            ]
        })
    };
    let exact = endpoints().find(|&(s, r)| s == schema && r == relation);
    let canonical = exact.or_else(|| {
        endpoints().find(|&(s, r)| match dialect {
            // Oracle's resolver tries the exact quoted spelling before uppercase SQL names.
            Dialect::Oracle => {
                s == schema.to_ascii_uppercase() && r == relation.to_ascii_uppercase()
            }
            Dialect::Sqlite | Dialect::MsSql | Dialect::MySql => {
                s.eq_ignore_ascii_case(schema) && r.eq_ignore_ascii_case(relation)
            }
            _ => false,
        })
    });
    canonical.map_or_else(
        || (schema.to_owned(), relation.to_owned()),
        |(schema, relation)| (schema.to_owned(), relation.to_owned()),
    )
}

fn relationship_node(relationship: RelationshipNode) -> Value {
    map(vec![
        ("name", Value::from(relationship.name)),
        ("source_schema", Value::from(relationship.source_schema)),
        ("source_relation", Value::from(relationship.source_relation)),
        ("columns", strings(relationship.columns)),
        ("target_schema", Value::from(relationship.target_schema)),
        ("target_relation", Value::from(relationship.target_relation)),
        ("referenced", strings(relationship.referenced)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> Vec<(&'static str, Value)> {
        vec![
            ("conn_id", Value::from(7)),
            ("schema", Value::from("")),
            ("relation", Value::from("order items")),
            ("request_id", Value::from(42)),
        ]
    }

    fn parse(pairs: Vec<(&str, Value)>) -> Result<Request, String> {
        Request::parse(&Args::from_params(&[map(pairs)]).unwrap())
    }

    fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
        value
            .as_map()?
            .iter()
            .find(|(name, _)| name.as_str() == Some(key))
            .map(|(_, value)| value)
    }

    #[test]
    fn relationships_accept_default_schema_and_preserve_identifiers() {
        let request = parse(params()).unwrap();
        assert_eq!(request.schema, "");
        assert_eq!(request.relation, "order items");
        assert_eq!(request.request_id, 42);
    }

    #[test]
    fn relationships_require_all_identity_fields() {
        for key in ["conn_id", "schema", "relation", "request_id"] {
            let pairs = params()
                .into_iter()
                .filter(|(name, _)| *name != key)
                .collect();
            assert!(parse(pairs).unwrap_err().contains(key));
        }
    }

    #[test]
    fn relationships_reject_wrong_types_and_invalid_values() {
        for (key, value) in [
            ("conn_id", Value::from("7")),
            ("schema", Value::from(1)),
            ("relation", Value::Nil),
            ("relation", Value::from("  ")),
            ("request_id", Value::from("42")),
            ("request_id", Value::from(1.5)),
            ("request_id", Value::from(-1)),
        ] {
            let mut pairs = params();
            pairs.iter_mut().find(|(name, _)| *name == key).unwrap().1 = value;
            assert!(parse(pairs).unwrap_err().contains(key));
        }
    }

    #[test]
    fn relationships_serialize_exact_fields_and_composite_column_order() {
        let node = relationship_node(RelationshipNode {
            name: "orders_customer_fk".to_owned(),
            source_schema: "sales".to_owned(),
            source_relation: "orders".to_owned(),
            columns: vec!["tenant_id".to_owned(), "customer_id".to_owned()],
            target_schema: "crm".to_owned(),
            target_relation: "customers".to_owned(),
            referenced: vec!["tenant_id".to_owned(), "id".to_owned()],
        });
        assert_eq!(node.as_map().unwrap().len(), 7);
        for (key, text) in [
            ("name", "orders_customer_fk"),
            ("source_schema", "sales"),
            ("source_relation", "orders"),
            ("target_schema", "crm"),
            ("target_relation", "customers"),
        ] {
            assert_eq!(field(&node, key).unwrap().as_str(), Some(text));
        }
        assert_eq!(
            field(&node, "columns"),
            Some(&strings(["tenant_id", "customer_id"]))
        );
        assert_eq!(
            field(&node, "referenced"),
            Some(&strings(["tenant_id", "id"]))
        );
    }

    #[test]
    fn relationships_completions_keep_identity_on_success_and_failure() {
        let request = parse(params()).unwrap();
        let success = request.completion(Ok(vec![]));
        let failure = request.completion(Err(DbError::driver("unsupported dialect")));
        for payload in [&success, &failure] {
            assert_eq!(field(payload, "conn_id"), Some(&Value::from(7)));
            assert_eq!(field(payload, "schema"), Some(&Value::from("")));
            assert_eq!(
                field(payload, "relation"),
                Some(&Value::from("order items"))
            );
            assert_eq!(field(payload, "request_id"), Some(&Value::from(42)));
            assert_eq!(payload.as_map().unwrap().len(), 5);
        }
        assert_eq!(
            field(&success, "relationships"),
            Some(&Value::Array(vec![]))
        );
        assert!(field(&success, "error").is_none());
        assert!(field(&failure, "relationships").is_none());
        assert!(
            field(&failure, "error")
                .unwrap()
                .as_str()
                .unwrap()
                .contains("unsupported dialect")
        );
    }

    #[test]
    fn canonical_endpoints_follow_the_dialects_identifier_rules() {
        let nodes = vec![RelationshipNode {
            name: "fk".into(),
            source_schema: "main".into(),
            source_relation: "Child".into(),
            columns: vec!["parent_id".into()],
            target_schema: "main".into(),
            target_relation: "Parent".into(),
            referenced: vec!["id".into()],
        }];
        assert_eq!(
            resolved_identity(Dialect::Sqlite, "main", "parent", &nodes),
            ("main".into(), "Parent".into())
        );
        assert_eq!(
            resolved_identity(Dialect::Postgres, "main", "parent", &nodes),
            ("main".into(), "parent".into())
        );
        let nodes = vec![RelationshipNode {
            name: "fk".into(),
            source_schema: "APP".into(),
            source_relation: "users".into(),
            columns: vec!["parent_id".into()],
            target_schema: "APP".into(),
            target_relation: "USERS".into(),
            referenced: vec!["id".into()],
        }];
        assert_eq!(
            resolved_identity(Dialect::Oracle, "APP", "Users", &nodes),
            ("APP".into(), "USERS".into())
        );
        assert_eq!(
            resolved_identity(Dialect::Oracle, "APP", "users", &nodes),
            ("APP".into(), "users".into())
        );
    }
}
