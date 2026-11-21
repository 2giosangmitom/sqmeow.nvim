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
            || matches!(name.as_str(), "BINDATA" | "BYTES" | "RAW" | "LONG RAW")
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
                    | "ROWID"
                    | "UROWID"
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
    use rstest::rstest;

    use super::*;

    #[rstest]
    #[case::postgres_numbers(TypeClass::Number, &["INT2", "INT4", "INT8", "NUMERIC", "FLOAT4", "FLOAT8", "OID", "MONEY"])]
    #[case::postgres_text(TypeClass::Text, &["TEXT", "VARCHAR", "BPCHAR", "CHAR", "NAME", "CITEXT"])]
    #[case::postgres_boolean(TypeClass::Boolean, &["BOOL"])]
    #[case::postgres_temporal(TypeClass::Temporal, &["DATE", "TIME", "TIMETZ", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL"])]
    #[case::postgres_json(TypeClass::Json, &["JSON", "JSONB"])]
    #[case::postgres_uuid(TypeClass::Uuid, &["UUID"])]
    #[case::postgres_binary(TypeClass::Binary, &["BYTEA"])]
    #[case::declared_text(TypeClass::Text, &["character varying(10)", "character(4)", "text"])]
    #[case::declared_numbers(TypeClass::Number, &["integer", "bigint", "numeric(30,3)", "double precision"])]
    #[case::declared_temporal(TypeClass::Temporal, &["timestamp with time zone", "time without time zone"])]
    #[case::declared_boolean(TypeClass::Boolean, &["boolean"])]
    #[case::mysql_numbers(TypeClass::Number, &["INT", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT", "DECIMAL", "DOUBLE", "int(11) unsigned", "bigint unsigned"])]
    #[case::mysql_text(TypeClass::Text, &["VARCHAR", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "ENUM", "SET", "varchar(255)"])]
    #[case::mysql_temporal(TypeClass::Temporal, &["DATETIME", "TIMESTAMP", "YEAR"])]
    #[case::mysql_binary(TypeClass::Binary, &["BLOB", "TINYBLOB", "LONGBLOB", "VARBINARY", "BINARY", "varbinary(16)"])]
    #[case::mysql_json(TypeClass::Json, &["JSON"])]
    #[case::sqlite_text(TypeClass::Text, &["TEXT", "VARCHAR(10)", "CLOB"])]
    #[case::sqlite_numbers(TypeClass::Number, &["INTEGER", "REAL", "NUMERIC"])]
    #[case::sqlite_boolean(TypeClass::Boolean, &["BOOLEAN"])]
    #[case::sqlite_unknown(TypeClass::Unknown, &["any", "", "NULL"])]
    #[case::cql_collections(TypeClass::Json, &["frozen<map<text, uuid>>", "set<int>"])]
    #[case::cql_uuid(TypeClass::Uuid, &["timeuuid"])]
    #[case::cql_text(TypeClass::Text, &["ascii"])]
    #[case::cql_numbers(TypeClass::Number, &["counter"])]
    #[case::cql_temporal(TypeClass::Temporal, &["duration"])]
    #[case::surreal_numbers(TypeClass::Number, &["int", "float", "decimal", "option<int>", "none | int"])]
    #[case::surreal_text(TypeClass::Text, &["string", "record", "record<person>"])]
    #[case::surreal_temporal(TypeClass::Temporal, &["datetime", "duration"])]
    #[case::surreal_json(TypeClass::Json, &["object", "array<string>", "set<int>"])]
    #[case::surreal_binary(TypeClass::Binary, &["bytes"])]
    #[case::surreal_unknown(TypeClass::Unknown, &["geometry<point>", "int | string"])]
    #[case::mongo_numbers(TypeClass::Number, &["int", "long", "double", "decimal"])]
    #[case::mongo_text(TypeClass::Text, &["string"])]
    #[case::mongo_boolean(TypeClass::Boolean, &["bool"])]
    #[case::mongo_temporal(TypeClass::Temporal, &["date", "timestamp"])]
    #[case::mongo_json(TypeClass::Json, &["object", "array"])]
    #[case::mongo_uuid(TypeClass::Uuid, &["objectId"])]
    #[case::mongo_binary(TypeClass::Binary, &["binData"])]
    #[case::numeric_array(TypeClass::Number, &["INT4[]"])]
    #[case::text_array(TypeClass::Text, &["text[]"])]
    #[case::geometry_is_not_numeric(TypeClass::Unknown, &["POINT", "polygon"])]
    #[case::unknown(TypeClass::Unknown, &["tsvector", "hstore"])]
    fn classifies_type_names(#[case] class: TypeClass, #[case] names: &[&str]) {
        for name in names {
            assert_eq!(TypeClass::from_type_name(name), class, "{name}");
        }
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
