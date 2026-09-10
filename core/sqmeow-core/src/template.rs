//! Filling in the secret parts of a connection URL.
//!
//! A URL is the one place a password would otherwise sit in plain text in a config file. Writing
//! it as a directive instead means the file can be committed and the secret stays where it lives:
//!
//! ```text
//! postgres://app:{{ env "PGPASSWORD" }}@localhost/dev
//! postgres://app:{{ exec "pass show db/prod" }}@db.internal/app
//! ```
//!
//! Expansion happens here, in the engine, and the expanded URL is never logged or sent back to the
//! editor. What the editor holds, and therefore what any interface can accidentally display, stays
//! the unexpanded form.

/// Expand every `{{ ... }}` directive in a string.
///
/// Text outside a directive is copied unchanged, so a URL with no directives costs one scan and no
/// allocation beyond the copy.
pub async fn expand(input: &str) -> Result<String, String> {
    if !input.contains("{{") {
        return Ok(input.to_owned());
    }

    let mut out = String::with_capacity(input.len());
    let mut rest = input;

    while let Some(open) = rest.find("{{") {
        out.push_str(&rest[..open]);

        let after = &rest[open + 2..];
        let close = after
            .find("}}")
            .ok_or_else(|| "a `{{` directive is never closed with `}}`".to_owned())?;

        out.push_str(&evaluate(after[..close].trim()).await?);
        rest = &after[close + 2..];
    }

    out.push_str(rest);
    Ok(out)
}

async fn evaluate(directive: &str) -> Result<String, String> {
    let (name, argument) = split(directive)?;

    match name {
        "env" => std::env::var(&argument)
            .map_err(|_| format!("the environment variable `{argument}` is not set")),
        "exec" => run(&argument).await,
        other => Err(format!(
            "unknown directive `{other}`; expected `env` or `exec`"
        )),
    }
}

/// Split `env "NAME"` into its directive and its argument.
///
/// Both quote styles are accepted, because a shell command in a URL frequently contains double
/// quotes of its own and backticks let it stay readable.
fn split(directive: &str) -> Result<(&str, String), String> {
    let (name, rest) = directive
        .split_once(char::is_whitespace)
        .ok_or_else(|| format!("`{directive}` takes an argument, as in `env \"NAME\"`"))?;

    let rest = rest.trim();
    let quote = rest
        .chars()
        .next()
        .filter(|character| *character == '"' || *character == '`')
        .ok_or_else(|| format!("the argument to `{name}` must be quoted"))?;

    let body = rest
        .strip_prefix(quote)
        .and_then(|body| body.strip_suffix(quote))
        .ok_or_else(|| format!("the argument to `{name}` is missing its closing quote"))?;

    Ok((name, body.to_owned()))
}

/// Run a command and take its output as the value.
///
/// This is a shell command from the user's own configuration, which is why it is allowed at all.
/// It is also why the failure message repeats the command: a password manager that is locked fails
/// here, and the user needs to see which command to unlock.
async fn run(command: &str) -> Result<String, String> {
    let output = shell(command)
        .await
        .map_err(|error| format!("`{command}` could not be run: {error}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("`{command}` failed: {}", stderr.trim()));
    }

    // A secret manager prints a trailing newline. Keeping it would produce a password with a
    // newline in it, and an authentication failure nobody could explain.
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned())
}

#[cfg(not(windows))]
async fn shell(command: &str) -> std::io::Result<std::process::Output> {
    tokio::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .output()
        .await
}

#[cfg(windows)]
async fn shell(command: &str) -> std::io::Result<std::process::Output> {
    tokio::process::Command::new("cmd")
        .args(["/C", command])
        .output()
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

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
        // A password with a newline on the end authenticates against nothing, and the failure
        // would look like a wrong password rather than a formatting problem.
        assert_eq!(
            expand("{{ exec \"printf 'a\\n\\n'\" }}").await.unwrap(),
            "a"
        );
    }

    #[tokio::test]
    async fn a_failing_command_reports_itself() {
        let error = expand("{{ exec \"exit 3\" }}").await.unwrap_err();
        assert!(error.contains("exit 3"), "{error}");
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
