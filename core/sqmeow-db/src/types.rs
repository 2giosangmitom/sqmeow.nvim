//! Classifies column types and key kinds.

/// What kind of value a column holds, as a small closed set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TypeClass {
    Text,
    Number,
    Boolean,
    /// A date, a time, a timestamp, or an interval.
    Temporal,
    Json,
    Uuid,
    /// A blob, a `bytea`, a `varbinary`.
    Binary,
    /// Nothing above, including a SQLite column declared with no type at all.
    #[default]
    Unknown,
}

impl TypeClass {
    /// The name both sides of the protocol use for this class.
    pub fn name(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Boolean => "boolean",
            Self::Temporal => "temporal",
            Self::Json => "json",
            Self::Uuid => "uuid",
            Self::Binary => "binary",
            Self::Unknown => "unknown",
        }
    }

    /// Resolve the name the protocol carries back to a class.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "text" => Some(Self::Text),
            "number" => Some(Self::Number),
            "boolean" => Some(Self::Boolean),
            "temporal" => Some(Self::Temporal),
            "json" => Some(Self::Json),
            "uuid" => Some(Self::Uuid),
            "binary" => Some(Self::Binary),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }

    /// Classify a type name, however the database spelled it.
    pub fn from_type_name(raw: &str) -> Self {
        let name = normalize_type_name(raw);

        // Geometric types are checked by name before anything else.
        if matches!(
            name.as_str(),
            "POINT" | "LINE" | "LSEG" | "BOX" | "PATH" | "POLYGON" | "CIRCLE"
        ) {
            return Self::Unknown;
        }

        // SurrealQL's optional forms, `option<int>` and `none | int`, are their inner type.
        if let Some(inner) = name
            .strip_prefix("OPTION<")
            .and_then(|rest| rest.strip_suffix('>'))
        {
            return Self::from_type_name(inner);
        }
        if name.contains(" | ") {
            let mut kinds = name
                .split(" | ")
                .filter(|kind| !matches!(*kind, "NONE" | "NULL"));
            return match (kinds.next(), kinds.next()) {
                (Some(only), None) => Self::from_type_name(only),
                _ => Self::Unknown,
            };
        }
        if name == "RECORD" || name.starts_with("RECORD<") {
            return Self::Text;
        }
        if name.starts_with("GEOMETRY") {
            return Self::Unknown;
        }

        let has = |needle: &str| name.contains(needle);

        // CQL collections, tuples and vectors, such as `frozen<list<int>>`.
        if has("<") {
            return Self::Json;
        }

        // Ordered, and the order is load-bearing.
        if has("JSON") || matches!(name.as_str(), "OBJECT" | "ARRAY") {
            Self::Json
        } else if has("UUID") || matches!(name.as_str(), "UNIQUEIDENTIFIER" | "OBJECTID") {
            Self::Uuid
        } else if has("BOOL") {
            Self::Boolean
        } else if has("BLOB")
            || has("BYTEA")
            || has("BINARY")
            || matches!(name.as_str(), "BINDATA" | "BYTES")
        {
            Self::Binary
        } else if has("TIMESTAMP")
            || has("DATETIME")
            || has("DATE")
            || has("TIME")
            || has("INTERVAL")
            || matches!(name.as_str(), "YEAR" | "DURATION")
        {
            Self::Temporal
        } else if has("INT")
            || has("NUMERIC")
            || has("DECIMAL")
            || has("FLOAT")
            || has("DOUBLE")
            || has("REAL")
            || has("SERIAL")
            || has("MONEY")
            || matches!(name.as_str(), "NUMBER" | "BIT" | "OID" | "LONG" | "COUNTER")
        {
            Self::Number
        } else if has("CHAR")
            || has("TEXT")
            || has("CLOB")
            || has("STRING")
            || has("XML")
            || matches!(
                name.as_str(),
                "NAME"
                    | "ENUM"
                    | "SET"
                    | "INET"
                    | "CIDR"
                    | "MACADDR"
                    | "MACADDR8"
                    | "CITEXT"
                    | "ASCII"
            )
        {
            Self::Text
        } else {
            Self::Unknown
        }
    }
}

/// Reduce a type name to the part worth matching on.
pub fn normalize_type_name(raw: &str) -> String {
    let mut name = raw.trim();
    if let Some((head, _)) = name.split_once('(') {
        name = head.trim_end();
    }
    while let Some(head) = name.strip_suffix("[]") {
        name = head.trim_end();
    }
    name.to_ascii_uppercase()
}

/// Whether a column is a key, and which kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum KeyKind {
    #[default]
    None,
    Primary,
    Foreign,
}

impl KeyKind {
    /// The name both sides of the protocol use, or `None` for a column that is not a key.
    pub fn name(self) -> Option<&'static str> {
        match self {
            Self::None => None,
            Self::Primary => Some("primary_key"),
            Self::Foreign => Some("foreign_key"),
        }
    }

    /// Whether this is a key at all.
    pub fn is_key(self) -> bool {
        !matches!(self, Self::None)
    }

    /// Resolve the name the protocol carries back to a kind.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "primary_key" => Some(Self::Primary),
            "foreign_key" => Some(Self::Foreign),
            _ => None,
        }
    }
}

/// What a foreign key points at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignKey {
    pub table: String,
    pub column: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[track_caller]
    fn assert_class(class: TypeClass, names: &[&str]) {
        for name in names {
            assert_eq!(
                TypeClass::from_type_name(name),
                class,
                "{name} should classify as {}",
                class.name()
            );
        }
    }

    #[test]
    fn postgres_driver_names_classify() {
        assert_class(
            TypeClass::Number,
            &[
                "INT2", "INT4", "INT8", "NUMERIC", "FLOAT4", "FLOAT8", "OID", "MONEY",
            ],
        );
        assert_class(
            TypeClass::Text,
            &["TEXT", "VARCHAR", "BPCHAR", "CHAR", "NAME", "CITEXT"],
        );
        assert_class(TypeClass::Boolean, &["BOOL"]);
        assert_class(
            TypeClass::Temporal,
            &[
                "DATE",
                "TIME",
                "TIMETZ",
                "TIMESTAMP",
                "TIMESTAMPTZ",
                "INTERVAL",
            ],
        );
        assert_class(TypeClass::Json, &["JSON", "JSONB"]);
        assert_class(TypeClass::Uuid, &["UUID"]);
        assert_class(TypeClass::Binary, &["BYTEA"]);
    }

    #[test]
    fn postgres_declared_names_classify_the_same_way() {
        // What `format_type` renders, which is what the drawer shows.
        assert_class(
            TypeClass::Text,
            &["character varying(10)", "character(4)", "text"],
        );
        assert_class(
            TypeClass::Number,
            &["integer", "bigint", "numeric(30,3)", "double precision"],
        );
        assert_class(
            TypeClass::Temporal,
            &["timestamp with time zone", "time without time zone"],
        );
        assert_class(TypeClass::Boolean, &["boolean"]);
    }

    #[test]
    fn mysql_names_classify() {
        assert_class(
            TypeClass::Number,
            &[
                "INT",
                "BIGINT",
                "SMALLINT",
                "TINYINT",
                "MEDIUMINT",
                "DECIMAL",
                "DOUBLE",
                "int(11) unsigned",
                "bigint unsigned",
            ],
        );
        assert_class(
            TypeClass::Text,
            &[
                "VARCHAR",
                "TINYTEXT",
                "MEDIUMTEXT",
                "LONGTEXT",
                "ENUM",
                "SET",
                "varchar(255)",
            ],
        );
        assert_class(TypeClass::Temporal, &["DATETIME", "TIMESTAMP", "YEAR"]);
        assert_class(
            TypeClass::Binary,
            &[
                "BLOB",
                "TINYBLOB",
                "LONGBLOB",
                "VARBINARY",
                "BINARY",
                "varbinary(16)",
            ],
        );
        assert_class(TypeClass::Json, &["JSON"]);
    }

    #[test]
    fn sqlite_names_classify() {
        assert_class(TypeClass::Text, &["TEXT", "VARCHAR(10)", "CLOB"]);
        assert_class(TypeClass::Number, &["INTEGER", "REAL", "NUMERIC"]);
        assert_class(TypeClass::Binary, &["BLOB"]);
        assert_class(TypeClass::Boolean, &["BOOLEAN"]);
        // A SQLite column may be declared with no type at all, which the adapter reports as "any".
        assert_class(TypeClass::Unknown, &["any", "", "NULL"]);
    }

    #[test]
    fn cql_names_classify() {
        assert_eq!(
            TypeClass::from_type_name("frozen<map<text, uuid>>"),
            TypeClass::Json
        );
        assert_eq!(TypeClass::from_type_name("set<int>"), TypeClass::Json);
        assert_eq!(TypeClass::from_type_name("timeuuid"), TypeClass::Uuid);
        assert_eq!(TypeClass::from_type_name("ascii"), TypeClass::Text);
        assert_eq!(TypeClass::from_type_name("counter"), TypeClass::Number);
        assert_eq!(TypeClass::from_type_name("duration"), TypeClass::Temporal);
    }

    #[test]
    fn surrealql_names_classify() {
        assert_class(
            TypeClass::Number,
            &["int", "float", "decimal", "option<int>", "none | int"],
        );
        assert_class(TypeClass::Text, &["string", "record", "record<person>"]);
        assert_class(TypeClass::Temporal, &["datetime", "duration"]);
        assert_class(TypeClass::Json, &["object", "array<string>", "set<int>"]);
        assert_class(TypeClass::Binary, &["bytes"]);
        assert_class(TypeClass::Unknown, &["geometry<point>", "int | string"]);
    }

    #[test]
    fn mongodb_names_classify() {
        assert_class(TypeClass::Number, &["int", "long", "double", "decimal"]);
        assert_class(TypeClass::Text, &["string"]);
        assert_class(TypeClass::Boolean, &["bool"]);
        assert_class(TypeClass::Temporal, &["date", "timestamp"]);
        assert_class(TypeClass::Json, &["object", "array"]);
        assert_class(TypeClass::Uuid, &["objectId"]);
        assert_class(TypeClass::Binary, &["binData"]);
    }

    #[test]
    fn an_array_takes_the_class_of_what_it_holds() {
        assert_eq!(TypeClass::from_type_name("INT4[]"), TypeClass::Number);
        assert_eq!(TypeClass::from_type_name("text[]"), TypeClass::Text);
    }

    #[test]
    fn a_point_is_not_a_number_despite_ending_in_int() {
        assert_eq!(TypeClass::from_type_name("POINT"), TypeClass::Unknown);
        assert_eq!(TypeClass::from_type_name("polygon"), TypeClass::Unknown);
    }

    #[test]
    fn an_unknown_type_is_not_guessed_at() {
        assert_eq!(TypeClass::from_type_name("tsvector"), TypeClass::Unknown);
        assert_eq!(TypeClass::from_type_name("hstore"), TypeClass::Unknown);
    }

    #[test]
    fn class_names_round_trip() {
        for class in [
            TypeClass::Text,
            TypeClass::Number,
            TypeClass::Boolean,
            TypeClass::Temporal,
            TypeClass::Json,
            TypeClass::Uuid,
            TypeClass::Binary,
            TypeClass::Unknown,
        ] {
            assert_eq!(TypeClass::from_name(class.name()), Some(class));
        }
        assert_eq!(TypeClass::from_name("geometry"), None);
    }

    #[test]
    fn a_type_name_normalizes_to_what_an_override_is_keyed_by() {
        assert_eq!(normalize_type_name("varchar(255)"), "VARCHAR");
        assert_eq!(normalize_type_name(" int4[] "), "INT4");
        assert_eq!(
            normalize_type_name("timestamp with time zone"),
            "TIMESTAMP WITH TIME ZONE"
        );
    }

    #[test]
    fn only_real_keys_are_keys() {
        assert!(!KeyKind::None.is_key());
        assert!(KeyKind::Primary.is_key());
        assert_eq!(KeyKind::None.name(), None);
        assert_eq!(KeyKind::Foreign.name(), Some("foreign_key"));
        assert_eq!(KeyKind::from_name("primary_key"), Some(KeyKind::Primary));
        assert_eq!(KeyKind::from_name("unique"), None);
    }
}
