//! Expands secret directives in a connection URL:
//!
//! ```text
//! postgres://app:{{ env "PGPASSWORD" }}@localhost/dev
//! postgres://app:{{ exec "pass show db/prod" }}@db.internal/app
//! postgres://app:{{ file "~/.secrets/db" }}@db.internal/app
//! ```
//!
//! The expanded URL is never logged or sent back to the editor. Expansion runs on the
//! user's machine with that user's environment, filesystem, and shell permissions; connection
//! definitions containing directives must therefore be treated as executable trusted input.

use std::collections::HashMap;
use std::path::Path;

/// Expand every `{{ ... }}` directive using the process environment.
///
/// `env` reads an environment variable, `file` reads a UTF-8 file (with `~/` expanded), and
/// `exec` runs the contents through the platform shell. Each directive is evaluated in source
/// order; values are inserted literally and are not recursively expanded. A command has a
/// 30-second deadline. Callers must avoid exposing the returned expanded string: it may contain
/// credentials.
///
/// # Errors
///
/// Returns an error for malformed or unknown directives, unavailable environment variables or
/// files, and commands that time out, cannot start, or exit unsuccessfully.
pub async fn expand(input: &str) -> Result<String, String> {
    expand_with_env_file(input, None).await
}

/// Expand directives with an optional project-local `.env` file as a fallback.
///
/// Process variables win. The file is reread for each connection, never loaded into
/// the process environment, and its values are never recursively evaluated.
/// Missing files are optional; other I/O and parse failures are reported without
/// including dotenv source lines, which may contain credentials.
pub async fn expand_with_env_file(input: &str, env_file: Option<&Path>) -> Result<String, String> {
    if !input.contains("{{") {
        return Ok(input.to_owned());
    }

    let local = match env_file {
        Some(path) => environment(path)?,
        None => HashMap::new(),
    };

    let mut out = String::with_capacity(input.len());
    let mut rest = input;

    while let Some(open) = rest.find("{{") {
        out.push_str(&rest[..open]);

        let after = &rest[open + 2..];
        let close = after
            .find("}}")
            .ok_or_else(|| "a `{{` directive is never closed with `}}`".to_owned())?;

        out.push_str(&evaluate(after[..close].trim(), &local).await?);
        rest = &after[close + 2..];
    }

    out.push_str(rest);
    Ok(out)
}

/// Parse dotenv without mutating the multi-threaded engine's global environment.
fn environment(path: &Path) -> Result<HashMap<String, String>, String> {
    let entries = match dotenvy::from_path_iter(path) {
        Ok(entries) => entries,
        Err(dotenvy::Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(HashMap::new());
        }
        Err(_) => {
            return Err(format!(
                "`{}` could not be read as a dotenv file",
                path.display()
            ));
        }
    };
    let mut values = HashMap::new();
    for entry in entries {
        let (name, value) = entry
            .map_err(|_| format!("`{}` could not be parsed as a dotenv file", path.display()))?;
        // Like dotenvy's non-overriding loader, the first definition wins.
        values.entry(name).or_insert(value);
    }
    Ok(values)
}

async fn evaluate(directive: &str, local: &HashMap<String, String>) -> Result<String, String> {
    let (name, argument) = split(directive)?;

    match name {
        "env" => std::env::var(&argument)
            .or_else(|_| {
                local
                    .get(&argument)
                    .cloned()
                    .ok_or(std::env::VarError::NotPresent)
            })
            .map_err(|_| format!("the environment variable `{argument}` is not set")),
        "exec" => run(&argument).await,
        "file" => read(&argument),
        other => Err(format!(
            "unknown directive `{other}`; expected `env`, `exec` or `file`"
        )),
    }
}

/// Split a directive at its first whitespace and remove its matching quote pair.
///
/// The grammar intentionally does not interpret escapes or nested quotes; the argument is passed
/// as-is to the selected directive handler.
fn split(directive: &str) -> Result<(&str, String), String> {
    let (name, rest) = directive
        .split_once(char::is_whitespace)
        .ok_or_else(|| format!("`{directive}` takes an argument, as in `env \"NAME\"`"))?;

    let rest = rest.trim();
    let quote = rest
        .chars()
        .next()
        .filter(|character| matches!(*character, '"' | '\'' | '`'))
        .ok_or_else(|| format!("the argument to `{name}` must be quoted"))?;

    let body = rest
        .strip_prefix(quote)
        .and_then(|body| body.strip_suffix(quote))
        .ok_or_else(|| format!("the argument to `{name}` is missing its closing quote"))?;

    Ok((name, body.to_owned()))
}

/// Take a file's contents as the value, `~/` standing for the home directory.
fn read(path: &str) -> Result<String, String> {
    let expanded = match (path.strip_prefix("~/"), std::env::var("HOME")) {
        (Some(rest), Ok(home)) => format!("{home}/{rest}"),
        _ => path.to_owned(),
    };
    std::fs::read_to_string(&expanded)
        // A file an editor saved ends in a newline that is not part of the secret.
        .map(|text| text.trim_end().to_owned())
        .map_err(|error| format!("`{path}` could not be read: {error}"))
}

/// The maximum time a `{{ exec }}` command may run before it is killed.
const EXEC_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Run a command and take its output as the value.
async fn run(command: &str) -> Result<String, String> {
    let output = tokio::time::timeout(EXEC_TIMEOUT, shell(command))
        .await
        .map_err(|_| {
            format!(
                "the configured command timed out after {}s",
                EXEC_TIMEOUT.as_secs()
            )
        })?
        .map_err(|_| "the configured command could not be started".to_owned())?;

    if !output.status.success() {
        // Commands and their diagnostics can contain the very secret being expanded.
        return Err(format!(
            "the configured command failed with {}",
            output
                .status
                .code()
                .map_or_else(|| "a signal".to_owned(), |code| format!("exit code {code}"))
        ));
    }

    // A secret manager prints a trailing newline.
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned())
}

#[cfg(not(windows))]
async fn shell(command: &str) -> std::io::Result<std::process::Output> {
    tokio::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .kill_on_drop(true)
        .output()
        .await
}

#[cfg(windows)]
async fn shell(command: &str) -> std::io::Result<std::process::Output> {
    tokio::process::Command::new("cmd")
        .args(["/C", command])
        .kill_on_drop(true)
        .output()
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Project(std::path::PathBuf);

    impl Project {
        fn new(contents: &str) -> Self {
            static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "sqmeow-dotenv-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(path.join(".env"), contents).unwrap();
            Self(path)
        }

        fn env_file(&self) -> std::path::PathBuf {
            self.0.join(".env")
        }
    }

    impl Drop for Project {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[tokio::test]
    async fn dotenv_values_are_scoped_and_do_not_modify_the_environment() {
        let one =
            Project::new("SQMEOW_DOTENV_URL='sqlite::memory:'\nSQMEOW_DOTENV_NOTE=\"two words\"\n");
        let two = Project::new("SQMEOW_DOTENV_URL=duckdb::memory:\n");
        let input = "{{ env 'SQMEOW_DOTENV_URL' }}";
        assert_eq!(
            expand_with_env_file(input, Some(&one.env_file()))
                .await
                .unwrap(),
            "sqlite::memory:"
        );
        assert_eq!(
            expand_with_env_file(input, Some(&two.env_file()))
                .await
                .unwrap(),
            "duckdb::memory:"
        );
        assert!(std::env::var("SQMEOW_DOTENV_URL").is_err());
        assert!(expand(input).await.is_err());
        assert_eq!(
            expand_with_env_file("{{ env `SQMEOW_DOTENV_NOTE` }}", Some(&one.env_file()))
                .await
                .unwrap(),
            "two words"
        );
    }

    #[tokio::test]
    async fn process_variables_take_precedence_over_dotenv() {
        let (name, value) = std::env::vars()
            .next()
            .expect("the test process has an environment");
        let project = Project::new(&format!("{name}=dotenv-must-not-win\n"));
        let input = format!("{{{{ env \"{name}\" }}}}");
        assert_eq!(
            expand_with_env_file(&input, Some(&project.env_file()))
                .await
                .unwrap(),
            value
        );
        std::fs::remove_file(project.env_file()).unwrap();
        assert_eq!(
            expand_with_env_file(&input, Some(&project.env_file()))
                .await
                .unwrap(),
            value
        );
    }

    #[tokio::test]
    async fn dotenv_is_reread_and_values_are_not_recursively_expanded() {
        let project = Project::new("SQMEOW_DOTENV_CHANGE=first\n");
        let input = "{{ env 'SQMEOW_DOTENV_CHANGE' }}";
        assert_eq!(
            expand_with_env_file(input, Some(&project.env_file()))
                .await
                .unwrap(),
            "first"
        );
        std::fs::write(
            project.env_file(),
            "SQMEOW_DOTENV_CHANGE='{{ exec \"echo secret\" }}'\n",
        )
        .unwrap();
        assert_eq!(
            expand_with_env_file(input, Some(&project.env_file()))
                .await
                .unwrap(),
            "{{ exec \"echo secret\" }}"
        );
    }

    #[tokio::test]
    async fn dotenv_errors_do_not_expose_secret_lines() {
        let project = Project::new("SECRET='private-secret\n");
        let error = expand_with_env_file("{{ env 'SECRET' }}", Some(&project.env_file()))
            .await
            .unwrap_err();
        assert!(error.contains(".env"), "{error}");
        assert!(!error.contains("private-secret"), "{error}");
        std::fs::remove_file(project.env_file()).unwrap();
        let error = expand_with_env_file(
            "{{ env 'SQMEOW_DOTENV_MISSING' }}",
            Some(&project.env_file()),
        )
        .await
        .unwrap_err();
        assert!(error.contains("SQMEOW_DOTENV_MISSING"), "{error}");
    }

    #[tokio::test]
    async fn text_without_directives_is_unchanged() {
        let url = "postgres://app@localhost/dev";
        assert_eq!(expand(url).await.unwrap(), url);
        assert_eq!(expand("").await.unwrap(), "");
    }

    #[tokio::test]
    async fn an_environment_variable_is_substituted() {
        // SAFETY: a name unique to this test, so no other test observes the change.
        unsafe { std::env::set_var("SQMEOW_TEMPLATE_ONE", "hunter2") };

        assert_eq!(
            expand("postgres://app:{{ env \"SQMEOW_TEMPLATE_ONE\" }}@host/db")
                .await
                .unwrap(),
            "postgres://app:hunter2@host/db"
        );
    }

    #[tokio::test]
    async fn several_directives_are_all_substituted() {
        unsafe { std::env::set_var("SQMEOW_TEMPLATE_USER", "app") };
        unsafe { std::env::set_var("SQMEOW_TEMPLATE_PASS", "secret") };

        assert_eq!(
            expand("postgres://{{ env \"SQMEOW_TEMPLATE_USER\" }}:{{ env \"SQMEOW_TEMPLATE_PASS\" }}@host/db")
                .await
                .unwrap(),
            "postgres://app:secret@host/db"
        );
    }

    #[tokio::test]
    async fn a_missing_environment_variable_names_itself() {
        let error = expand("{{ env \"SQMEOW_TEMPLATE_ABSENT\" }}")
            .await
            .unwrap_err();
        assert!(error.contains("SQMEOW_TEMPLATE_ABSENT"), "{error}");
    }

    #[tokio::test]
    async fn a_command_supplies_its_output() {
        assert_eq!(
            expand("{{ exec \"echo hunter2\" }}").await.unwrap(),
            "hunter2"
        );
    }

    #[tokio::test]
    async fn a_commands_trailing_newline_is_dropped() {
        // A password with a newline on the end authenticates against nothing, and the failure would
        // look like a wrong password rather than a formatting problem.
        assert_eq!(
            expand("{{ exec \"printf 'a\\n\\n'\" }}").await.unwrap(),
            "a"
        );
    }

    #[tokio::test]
    async fn a_failing_command_does_not_echo_its_contents() {
        let error = expand("{{ exec \"echo hunter2 && exit 3\" }}")
            .await
            .unwrap_err();
        assert!(error.contains("exit code 3"), "{error}");
        assert!(!error.contains("hunter2"), "{error}");
    }

    #[tokio::test]
    async fn backticks_quote_an_argument_too() {
        assert_eq!(expand("{{ exec `echo hi` }}").await.unwrap(), "hi");
    }

    #[tokio::test]
    async fn an_unknown_directive_says_what_is_allowed() {
        let error = expand("{{ read \"file\" }}").await.unwrap_err();
        assert!(error.contains("env"), "{error}");
        assert!(error.contains("exec"), "{error}");
    }

    #[tokio::test]
    async fn a_file_supplies_its_contents() {
        let path = std::env::temp_dir().join(format!("sqmeow-secret-{}", std::process::id()));
        std::fs::write(&path, "hunter2\n").unwrap();
        assert_eq!(
            expand(&format!("{{{{ file \"{}\" }}}}", path.display()))
                .await
                .unwrap(),
            "hunter2"
        );
        std::fs::remove_file(&path).unwrap();

        let error = expand("{{ file \"/nonexistent/secret\" }}")
            .await
            .unwrap_err();
        assert!(error.contains("/nonexistent/secret"), "{error}");
    }

    #[tokio::test]
    async fn an_unclosed_directive_is_rejected() {
        assert!(expand("postgres://{{ env \"X\"").await.is_err());
    }

    #[tokio::test]
    async fn an_unquoted_argument_is_rejected() {
        assert!(expand("{{ env PGPASSWORD }}").await.is_err());
    }

    #[tokio::test]
    async fn a_directive_with_no_argument_is_rejected() {
        assert!(expand("{{ env }}").await.is_err());
    }
}
